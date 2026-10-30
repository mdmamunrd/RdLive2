package api

import (
	"context"
	"errors"
	"net/http"

	"github.com/jackc/pgx/v5"

	"rdlive/internal/coinx"
	"rdlive/internal/roomx"
)

// ---------------------------------------------------------------------------------------------
// Home feed
// ---------------------------------------------------------------------------------------------

// GET /v1/rooms?tab=discover|new|follow&limit=
// Same JSON as the Flutter LiveRoom model: {"rooms":[{id, host_name, country_code, cover_url, badge, audience_avatars, ...}]}
// Rooms of hosts who blocked you (or whom you blocked) never show up.
func (a *API) roomFeed(w http.ResponseWriter, r *http.Request) {
	uid := userID(r.Context())
	limit, _ := paging(r)
	var join, order string
	switch r.URL.Query().Get("tab") {
	case "", "discover":
		order = "f.viewer_count desc, f.started_at desc"
	case "new":
		order = "f.started_at desc"
	case "follow":
		join = "join follows fo on fo.followee_id = lr.host_id and fo.follower_id = $1"
		order = "f.viewer_count desc, f.started_at desc"
	default:
		writeErr(w, http.StatusBadRequest, "bad_request", "tab must be discover, new or follow")
		return
	}
	rows, err := a.DB.Query(r.Context(), `
		select f.id, f.host_name, coalesce(f.country_code,'BD'), f.cover_url, f.badge, f.audience_avatars,
		       f.viewer_count, f.media_mode::text, f.seat_count, f.is_password_protected
		from v_live_rooms_feed f
		join live_rooms lr on lr.id = f.id
		`+join+`
		where not exists (select 1 from user_blocks b
		                   where (b.blocker_id=$1 and b.blocked_id=lr.host_id) or (b.blocker_id=lr.host_id and b.blocked_id=$1))
		  and not exists (select 1 from room_bans rb where rb.host_id=lr.host_id and rb.user_id=$1 and rb.lifted_at is null)
		order by `+order+` limit $2`, uid, limit)
	if err != nil {
		dbErr(w, "roomFeed", err)
		return
	}
	defer rows.Close()
	type room struct {
		ID               int64    `json:"id"`
		HostName         string   `json:"host_name"`
		CountryCode      string   `json:"country_code"`
		CoverURL         *string  `json:"cover_url"`
		Badge            *string  `json:"badge"`
		AudienceAvatars  []string `json:"audience_avatars"`
		ViewerCount      int32    `json:"viewer_count"`
		MediaMode        string   `json:"media_mode"`
		SeatCount        int16    `json:"seat_count"`
		PasswordRequired bool     `json:"password_required"`
	}
	out := []room{}
	for rows.Next() {
		var x room
		if err := rows.Scan(&x.ID, &x.HostName, &x.CountryCode, &x.CoverURL, &x.Badge, &x.AudienceAvatars,
			&x.ViewerCount, &x.MediaMode, &x.SeatCount, &x.PasswordRequired); err != nil {
			dbErr(w, "roomFeed scan", err)
			return
		}
		if x.AudienceAvatars == nil {
			x.AudienceAvatars = []string{}
		}
		out = append(out, x)
	}
	if err := rows.Err(); err != nil {
		dbErr(w, "roomFeed rows", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"rooms": out})
}

// ---------------------------------------------------------------------------------------------
// Room lifecycle
// ---------------------------------------------------------------------------------------------

func (a *API) roomSecret() []byte { return []byte("room-pw:" + a.Cfg.JWTSecret) }

// exec runs a void SQL function and answers {"ok":true}.
func (a *API) exec(w http.ResponseWriter, r *http.Request, op, sql string, args ...any) bool {
	err := withRetry(func() error {
		_, e := a.DB.Exec(r.Context(), sql, args...)
		return e
	})
	if err != nil {
		dbErr(w, op, err)
		return false
	}
	return true
}

func (a *API) execOK(w http.ResponseWriter, r *http.Request, op, sql string, args ...any) {
	if a.exec(w, r, op, sql, args...) {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	}
}

// POST /v1/rooms   {title?, seat_count?(4|6|8|9|12, default 8), media_mode?("audio"|"video"), password?, require_approval?}
func (a *API) roomCreate(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Title           string `json:"title"`
		SeatCount       int    `json:"seat_count"`
		MediaMode       string `json:"media_mode"`
		Password        string `json:"password"`
		RequireApproval *bool  `json:"require_approval"`
	}
	if !decode(w, r, &req) {
		return
	}
	title, ok := coinx.CleanText(req.Title, 60)
	if !ok {
		writeErr(w, http.StatusBadRequest, "bad_request", "invalid title")
		return
	}
	if req.SeatCount == 0 {
		req.SeatCount = 8
	}
	switch req.SeatCount {
	case 4, 6, 8, 9, 12:
	default:
		writeErr(w, http.StatusBadRequest, "bad_request", "seat_count must be 4, 6, 8, 9 or 12")
		return
	}
	if req.MediaMode == "" {
		req.MediaMode = "audio"
	}
	if req.MediaMode != "audio" && req.MediaMode != "video" {
		writeErr(w, http.StatusBadRequest, "bad_request", "media_mode must be audio or video")
		return
	}
	var pwHash *string
	if req.Password != "" {
		if !roomx.ValidPassword(req.Password) {
			writeErr(w, http.StatusBadRequest, "bad_request", "password must be 4-16 characters")
			return
		}
		h := roomx.Hash(a.roomSecret(), req.Password)
		pwHash = &h
	}
	approval := true
	if req.RequireApproval != nil {
		approval = *req.RequireApproval
	}
	var id int64
	err := a.DB.QueryRow(r.Context(), `select room_create($1,$2,$3,$4::room_media_mode,$5,$6)`,
		userID(r.Context()), nullable(title), req.SeatCount, req.MediaMode, pwHash, approval).Scan(&id)
	if err != nil {
		dbErr(w, "room_create", err)
		return
	}
	var channel string
	_ = a.DB.QueryRow(r.Context(), `select agora_channel from live_rooms where id=$1`, id).Scan(&channel)
	writeJSON(w, http.StatusCreated, map[string]any{"room_id": id, "agora_channel": channel})
}

// POST /v1/rooms/{id}/join   {password?}   -> {role}
func (a *API) roomJoin(w http.ResponseWriter, r *http.Request) {
	id, ok := pathInt(w, r, "id")
	if !ok {
		return
	}
	var req struct {
		Password string `json:"password"`
	}
	if r.ContentLength != 0 && !decode(w, r, &req) {
		return
	}
	uid := userID(r.Context())
	var host int64
	var hash *string
	err := a.DB.QueryRow(r.Context(), `select host_id, password_hash from live_rooms where id=$1 and status='live'`, id).Scan(&host, &hash)
	if err != nil {
		notFoundOr500(w, "roomJoin lookup", err, "room")
		return
	}
	if hash != nil && uid != host && !roomx.Check(a.roomSecret(), *hash, req.Password) {
		writeErr(w, http.StatusForbidden, "wrong_password", "wrong room password")
		return
	}
	var role string
	if err := withRetry(func() error {
		return a.DB.QueryRow(r.Context(), `select room_join($1,$2)::text`, id, uid).Scan(&role)
	}); err != nil {
		dbErr(w, "room_join", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"role": role})
}

// POST /v1/rooms/{id}/leave
func (a *API) roomLeave(w http.ResponseWriter, r *http.Request) {
	if id, ok := pathInt(w, r, "id"); ok {
		a.execOK(w, r, "room_leave", `select room_leave($1,$2)`, id, userID(r.Context()))
	}
}

// POST /v1/rooms/{id}/end
func (a *API) roomEnd(w http.ResponseWriter, r *http.Request) {
	if id, ok := pathInt(w, r, "id"); ok {
		a.execOK(w, r, "room_end", `select room_end($1,$2)`, id, userID(r.Context()))
	}
}

// PATCH /v1/rooms/{id}   {seat_count?, require_approval?}      host only
func (a *API) roomPatch(w http.ResponseWriter, r *http.Request) {
	id, ok := pathInt(w, r, "id")
	if !ok {
		return
	}
	var req struct {
		SeatCount       *int  `json:"seat_count"`
		RequireApproval *bool `json:"require_approval"`
	}
	if !decode(w, r, &req) {
		return
	}
	if req.SeatCount == nil && req.RequireApproval == nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "nothing to update")
		return
	}
	uid := userID(r.Context())
	if req.SeatCount != nil {
		switch *req.SeatCount {
		case 4, 6, 8, 9, 12:
		default:
			writeErr(w, http.StatusBadRequest, "bad_request", "seat_count must be 4, 6, 8, 9 or 12")
			return
		}
		if !a.exec(w, r, "room_set_layout", `select room_set_layout($1,$2,$3)`, id, uid, *req.SeatCount) {
			return
		}
	}
	if req.RequireApproval != nil {
		if !a.exec(w, r, "room_set_require_approval", `select room_set_require_approval($1,$2,$3)`, id, uid, *req.RequireApproval) {
			return
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// GET /v1/rooms/{id}   full snapshot for a room member: seats, people, (staff: requests + banned), running PK.
// Call it after join, and again whenever the WebSocket says {"type":"resync"}.
func (a *API) roomSnapshot(w http.ResponseWriter, r *http.Request) {
	id, ok := pathInt(w, r, "id")
	if !ok {
		return
	}
	uid := userID(r.Context())
	var role string
	err := a.DB.QueryRow(r.Context(), `select role::text from room_members where room_id=$1 and user_id=$2 and left_at is null`, id, uid).Scan(&role)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			writeErr(w, http.StatusForbidden, "not_in_room", "join the room first")
			return
		}
		dbErr(w, "roomSnapshot role", err)
		return
	}
	staff := role == "host" || role == "moderator"
	var js string
	err = a.DB.QueryRow(r.Context(), `
		select jsonb_build_object(
		  'my_user_id', $2::bigint, 'my_role', $3::text,
		  'room', (select to_jsonb(x) from (
		            select r.id, r.host_id, r.title, r.seat_count, r.media_mode::text as media_mode, r.require_approval,
		                   r.viewer_count, r.is_password_protected, r.status, r.started_at, r.agora_channel
		            from live_rooms r where r.id=$1) x),
		  'seats',    (select coalesce(jsonb_agg(to_jsonb(s) order by s.seat_index), '[]'::jsonb) from v_room_seats s where s.room_id=$1),
		  'members',  (select coalesce(jsonb_agg(to_jsonb(m) order by m.joined_at), '[]'::jsonb) from v_room_members m where m.room_id=$1),
		  'requests', (select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at), '[]'::jsonb) from v_room_seat_requests q where q.room_id=$1 and $4::boolean),
		  'banned',   (select coalesce(jsonb_agg(to_jsonb(b) order by b.created_at desc), '[]'::jsonb) from v_room_banned b where b.room_id=$1 and $4::boolean),
		  'pk',       (select to_jsonb(p) from v_pk_battle_state p
		                where p.status in ('ready','running') and (p.room_a=$1 or p.room_b=$1) order by p.id desc limit 1)
		)::text`, id, uid, role, staff).Scan(&js)
	if err != nil {
		dbErr(w, "roomSnapshot", err)
		return
	}
	rawJSON(w, http.StatusOK, js)
}

func rawJSON(w http.ResponseWriter, status int, js string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write([]byte(js))
}

// ---------------------------------------------------------------------------------------------
// Seats
// ---------------------------------------------------------------------------------------------

// POST /v1/rooms/{id}/seats/request   {seat_index?}  -> {"result":"seated","seat_index":n} | {"result":"pending","request_id":n}
func (a *API) seatRequest(w http.ResponseWriter, r *http.Request) {
	id, ok := pathInt(w, r, "id")
	if !ok {
		return
	}
	var req struct {
		SeatIndex *int `json:"seat_index"`
	}
	if r.ContentLength != 0 && !decode(w, r, &req) {
		return
	}
	if req.SeatIndex != nil && (*req.SeatIndex < 0 || *req.SeatIndex > 11) {
		writeErr(w, http.StatusBadRequest, "bad_request", "invalid seat_index")
		return
	}
	var js string
	if err := withRetry(func() error {
		return a.DB.QueryRow(r.Context(), `select seat_request_create($1,$2,$3)::text`, id, userID(r.Context()), req.SeatIndex).Scan(&js)
	}); err != nil {
		dbErr(w, "seat_request_create", err)
		return
	}
	rawJSON(w, http.StatusOK, js)
}

// DELETE /v1/rooms/{id}/seats/request
func (a *API) seatRequestCancel(w http.ResponseWriter, r *http.Request) {
	if id, ok := pathInt(w, r, "id"); ok {
		a.execOK(w, r, "seat_request_cancel", `select seat_request_cancel($1,$2)`, id, userID(r.Context()))
	}
}

// POST /v1/rooms/{id}/seats/leave
func (a *API) seatLeave(w http.ResponseWriter, r *http.Request) {
	if id, ok := pathInt(w, r, "id"); ok {
		a.execOK(w, r, "seat_leave", `select seat_leave($1,$2)`, id, userID(r.Context()))
	}
}

// PATCH /v1/rooms/{id}/seats/me   {mic?, camera?}
func (a *API) seatMedia(w http.ResponseWriter, r *http.Request) {
	id, ok := pathInt(w, r, "id")
	if !ok {
		return
	}
	var req struct {
		Mic    *bool `json:"mic"`
		Camera *bool `json:"camera"`
	}
	if !decode(w, r, &req) {
		return
	}
	if req.Mic == nil && req.Camera == nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "mic or camera required")
		return
	}
	a.execOK(w, r, "seat_set_media", `select seat_set_media($1,$2,$3,$4)`, id, userID(r.Context()), req.Mic, req.Camera)
}

// POST /v1/rooms/{id}/seats/{n}/lock | unlock     staff
func (a *API) seatLock(lock bool) http.HandlerFunc {
	fn := "seat_unlock"
	if lock {
		fn = "seat_lock"
	}
	return func(w http.ResponseWriter, r *http.Request) {
		id, ok := pathInt(w, r, "id")
		if !ok {
			return
		}
		n, ok := pathInt(w, r, "n")
		if !ok {
			return
		}
		a.execOK(w, r, fn, `select `+fn+`($1,$2,$3)`, id, userID(r.Context()), n)
	}
}

// POST /v1/rooms/{id}/requests/{rid}   {approve: bool, seat_index?}   staff
func (a *API) seatResolve(w http.ResponseWriter, r *http.Request) {
	id, ok := pathInt(w, r, "id")
	if !ok {
		return
	}
	rid, ok := pathInt(w, r, "rid")
	if !ok {
		return
	}
	var req struct {
		Approve   *bool `json:"approve"`
		SeatIndex *int  `json:"seat_index"`
	}
	if !decode(w, r, &req) {
		return
	}
	if req.Approve == nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "approve is required")
		return
	}
	var seat *int32
	if err := withRetry(func() error {
		return a.DB.QueryRow(r.Context(), `select seat_request_resolve($1,$2,$3,$4,$5)`,
			id, userID(r.Context()), rid, *req.Approve, req.SeatIndex).Scan(&seat)
	}); err != nil {
		dbErr(w, "seat_request_resolve", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "seat_index": seat})
}

// ---------------------------------------------------------------------------------------------
// Moderation: POST /v1/rooms/{id}/members/{uid}/{action}
//
//	action = mute | unmute | kick | ban | unban | remove-seat | role      (role body: {"role":"moderator"|"audience"})
//
// ---------------------------------------------------------------------------------------------
func (a *API) memberAction(w http.ResponseWriter, r *http.Request) {
	id, ok := pathInt(w, r, "id")
	if !ok {
		return
	}
	target, ok := pathInt(w, r, "uid")
	if !ok {
		return
	}
	actor := userID(r.Context())
	switch action := pathString(r, "action"); action {
	case "mute", "unmute":
		a.execOK(w, r, "room_mute_user", `select room_mute_user($1,$2,$3,$4)`, id, actor, target, action == "mute")
	case "kick":
		a.execOK(w, r, "room_kick_user", `select room_kick_user($1,$2,$3)`, id, actor, target)
	case "ban":
		var req struct {
			Reason string `json:"reason"`
		}
		if r.ContentLength != 0 && !decode(w, r, &req) {
			return
		}
		reason, ok := coinx.CleanReason(req.Reason)
		if !ok {
			writeErr(w, http.StatusBadRequest, "bad_request", "invalid reason")
			return
		}
		a.execOK(w, r, "room_ban_user", `select room_ban_user($1,$2,$3,$4)`, id, actor, target, nullable(reason))
	case "unban":
		a.execOK(w, r, "room_unban_user", `select room_unban_user($1,$2,$3)`, id, actor, target)
	case "remove-seat":
		a.execOK(w, r, "seat_remove_user", `select seat_remove_user($1,$2,$3)`, id, actor, target)
	case "role":
		var req struct {
			Role string `json:"role"`
		}
		if !decode(w, r, &req) {
			return
		}
		if req.Role != "moderator" && req.Role != "audience" {
			writeErr(w, http.StatusBadRequest, "bad_request", "role must be moderator or audience")
			return
		}
		a.execOK(w, r, "room_set_role", `select room_set_role($1,$2,$3,$4::room_role)`, id, actor, target, req.Role)
	default:
		writeErr(w, http.StatusNotFound, "not_found", "unknown action")
	}
}

// ---------------------------------------------------------------------------------------------
// PK battle
// ---------------------------------------------------------------------------------------------

// POST /v1/pk   {room_a, room_b, duration_seconds?}    caller must be the host of room_a
func (a *API) pkCreate(w http.ResponseWriter, r *http.Request) {
	var req struct {
		RoomA    int64 `json:"room_a"`
		RoomB    int64 `json:"room_b"`
		Duration int   `json:"duration_seconds"`
	}
	if !decode(w, r, &req) {
		return
	}
	if req.Duration == 0 {
		req.Duration = 300
	}
	if req.RoomA <= 0 || req.RoomB <= 0 || req.Duration < 30 || req.Duration > 3600 {
		writeErr(w, http.StatusBadRequest, "bad_request", "invalid rooms or duration (30-3600 s)")
		return
	}
	var id int64
	if err := withRetry(func() error {
		return a.DB.QueryRow(r.Context(), `select pk_create($1,$2,$3,$4)`, userID(r.Context()), req.RoomA, req.RoomB, req.Duration).Scan(&id)
	}); err != nil {
		dbErr(w, "pk_create", err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"battle_id": id})
}

// GET /v1/pk/{id}
func (a *API) pkGet(w http.ResponseWriter, r *http.Request) {
	id, ok := pathInt(w, r, "id")
	if !ok {
		return
	}
	var js string
	if err := a.DB.QueryRow(r.Context(), `select to_jsonb(p)::text from v_pk_battle_state p where p.id=$1`, id).Scan(&js); err != nil {
		notFoundOr500(w, "pkGet", err, "battle")
		return
	}
	rawJSON(w, http.StatusOK, js)
}

// POST /v1/pk/{id}/start | finish | rematch      battling hosts only
func (a *API) pkAction(w http.ResponseWriter, r *http.Request) {
	id, ok := pathInt(w, r, "id")
	if !ok {
		return
	}
	uid := userID(r.Context())
	switch pathString(r, "action") {
	case "start":
		a.execOK(w, r, "pk_start", `select pk_start($1,$2)`, id, uid)
	case "finish":
		a.execOK(w, r, "pk_finish", `select pk_finish($1,$2)`, id, uid)
	case "rematch":
		var nid int64
		if err := withRetry(func() error {
			return a.DB.QueryRow(r.Context(), `select pk_rematch($1,$2)`, id, uid).Scan(&nid)
		}); err != nil {
			dbErr(w, "pk_rematch", err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"battle_id": nid})
	default:
		writeErr(w, http.StatusNotFound, "not_found", "unknown action")
	}
}

// finishDuePK is what the ticker calls. pg_try_advisory_xact_lock makes replicas take turns.
func (a *API) finishDuePK(ctx context.Context) (int, error) {
	var n int
	err := a.DB.QueryRow(ctx, `select case when pg_try_advisory_xact_lock(7001) then pk_finish_due() else 0 end`).Scan(&n)
	return n, err
}
