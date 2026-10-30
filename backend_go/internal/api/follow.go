package api

import (
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"

	"rdlive/internal/coinx"
)

// targetUser resolves {publicID} (the 8-digit id people see) to the internal user.
func (a *API) targetUser(w http.ResponseWriter, r *http.Request) (userRef, bool) {
	pid, err := strconv.ParseInt(chi.URLParam(r, "publicID"), 10, 64)
	if err != nil || !coinx.ValidPublicID(pid) {
		writeErr(w, http.StatusBadRequest, "bad_request", "invalid public id")
		return userRef{}, false
	}
	u, err := a.userByPublicID(r.Context(), pid)
	if err != nil {
		notFoundOr500(w, "targetUser", err, "user")
		return userRef{}, false
	}
	return u, true
}

// POST /v1/users/{publicID}/follow      DELETE = unfollow       (both idempotent)
func (a *API) followUser(w http.ResponseWriter, r *http.Request) {
	u, ok := a.targetUser(w, r)
	if !ok {
		return
	}
	var changed bool
	if err := a.DB.QueryRow(r.Context(), `select follow_user($1,$2)`, userID(r.Context()), u.ID).Scan(&changed); err != nil {
		dbErr(w, "follow_user", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"following": true, "changed": changed})
}

func (a *API) unfollowUser(w http.ResponseWriter, r *http.Request) {
	u, ok := a.targetUser(w, r)
	if !ok {
		return
	}
	var changed bool
	if err := a.DB.QueryRow(r.Context(), `select unfollow_user($1,$2)`, userID(r.Context()), u.ID).Scan(&changed); err != nil {
		dbErr(w, "unfollow_user", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"following": false, "changed": changed})
}

// POST /v1/users/{publicID}/block      DELETE = unblock
// Blocking removes follows both ways and stops messages / follows in both directions.
func (a *API) blockUser(w http.ResponseWriter, r *http.Request) {
	u, ok := a.targetUser(w, r)
	if !ok {
		return
	}
	if _, err := a.DB.Exec(r.Context(), `select block_user($1,$2)`, userID(r.Context()), u.ID); err != nil {
		dbErr(w, "block_user", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"blocked": true})
}

func (a *API) unblockUser(w http.ResponseWriter, r *http.Request) {
	u, ok := a.targetUser(w, r)
	if !ok {
		return
	}
	if _, err := a.DB.Exec(r.Context(), `select unblock_user($1,$2)`, userID(r.Context()), u.ID); err != nil {
		dbErr(w, "unblock_user", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"blocked": false})
}

type personItem struct {
	FollowID    int64     `json:"-"`
	PublicID    int64     `json:"public_id"`
	DisplayName string    `json:"display_name"`
	AvatarURL   string    `json:"avatar_url"`
	CountryCode string    `json:"country_code"`
	Level       int32     `json:"level"`
	LiveRoomID  *int64    `json:"live_room_id"` // non-null = currently live (show the red "LIVE" ring)
	Since       time.Time `json:"since"`
}

func (a *API) listPeople(w http.ResponseWriter, r *http.Request, query string) {
	limit, before := paging(r)
	rows, err := a.DB.Query(r.Context(), query, userID(r.Context()), before, limit)
	if err != nil {
		dbErr(w, "listPeople", err)
		return
	}
	defer rows.Close()
	items := []personItem{}
	for rows.Next() {
		var p personItem
		if err := rows.Scan(&p.FollowID, &p.PublicID, &p.DisplayName, &p.AvatarURL, &p.CountryCode, &p.Level, &p.LiveRoomID, &p.Since); err != nil {
			dbErr(w, "listPeople scan", err)
			return
		}
		items = append(items, p)
	}
	if err := rows.Err(); err != nil {
		dbErr(w, "listPeople rows", err)
		return
	}
	var next int64
	if len(items) == limit {
		next = items[len(items)-1].FollowID
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "next_before_id": next})
}

const peopleCols = `f.id, u.public_id, u.display_name, coalesce(u.avatar_url,''), coalesce(u.country_code,'BD'), u.level,
	(select r.id from live_rooms r where r.host_id = u.id and r.status = 'live' limit 1), f.created_at`

// GET /v1/me/following?limit=&before_id=
func (a *API) myFollowing(w http.ResponseWriter, r *http.Request) {
	a.listPeople(w, r, `select `+peopleCols+`
		from follows f join users u on u.id = f.followee_id
		where f.follower_id=$1 and u.status='active' and ($2::bigint=0 or f.id<$2::bigint)
		order by f.id desc limit $3`)
}

// GET /v1/me/followers?limit=&before_id=
func (a *API) myFollowers(w http.ResponseWriter, r *http.Request) {
	a.listPeople(w, r, `select `+peopleCols+`
		from follows f join users u on u.id = f.follower_id
		where f.followee_id=$1 and u.status='active' and ($2::bigint=0 or f.id<$2::bigint)
		order by f.id desc limit $3`)
}

// GET /v1/users/{publicID}     public profile card (follow button state, counters, live ring)
func (a *API) userCard(w http.ResponseWriter, r *http.Request) {
	u, ok := a.targetUser(w, r)
	if !ok {
		return
	}
	me := userID(r.Context())
	var (
		avatar, country, role         string
		level                         int32
		followers, following          int64
		isFollowing, followsMe, block bool
		blockedMe                     bool
		live                          *int64
	)
	err := a.DB.QueryRow(r.Context(), `
		select coalesce(u.avatar_url,''), coalesce(u.country_code,'BD'), u.role::text, u.level,
		       coalesce(s.followers,0), coalesce(s.following,0),
		       exists(select 1 from follows where follower_id=$2 and followee_id=u.id),
		       exists(select 1 from follows where follower_id=u.id and followee_id=$2),
		       exists(select 1 from user_blocks where blocker_id=$2 and blocked_id=u.id),
		       exists(select 1 from user_blocks where blocker_id=u.id and blocked_id=$2),
		       (select r.id from live_rooms r where r.host_id=u.id and r.status='live' limit 1)
		from users u left join follow_stats s on s.user_id=u.id
		where u.id=$1 and u.status='active'`, u.ID, me).
		Scan(&avatar, &country, &role, &level, &followers, &following, &isFollowing, &followsMe, &block, &blockedMe, &live)
	if err != nil {
		notFoundOr500(w, "userCard", err, "user")
		return
	}
	if blockedMe { // do not reveal anything about someone who blocked you
		writeErr(w, http.StatusNotFound, "not_found", "user not found")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"public_id": u.PublicID, "display_name": u.DisplayName, "avatar_url": avatar, "country_code": country,
		"level": level, "is_host": role == "host", "followers": followers, "following": following,
		"is_following": isFollowing, "follows_me": followsMe, "is_blocked": block, "live_room_id": live,
		"is_me": u.ID == me,
	})
}
