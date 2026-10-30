package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"

	"rdlive/internal/coinx"
)

// ---- message JSON ------------------------------------------------------------

type chatMedia struct {
	ID     string `json:"id"`
	URL    string `json:"url"`
	Mime   string `json:"mime"`
	Width  *int32 `json:"width,omitempty"`
	Height *int32 `json:"height,omitempty"`
}

type chatMessage struct {
	ID             int64      `json:"id"`
	ConversationID int64      `json:"conversation_id"`
	SenderID       int64      `json:"sender_id"`
	Kind           string     `json:"kind"` // text | image
	Body           *string    `json:"body,omitempty"`
	Media          *chatMedia `json:"media,omitempty"`
	ClientMsgID    *string    `json:"client_msg_id,omitempty"`
	CreatedAt      time.Time  `json:"created_at"`
	Read           bool       `json:"read"` // the OTHER person has read it
}

// read = the receiver's read watermark has passed this message
const msgSelect = `
	select m.id, m.conversation_id, m.sender_id, m.kind::text, m.body, m.client_msg_id, m.created_at,
	       ma.id::text, ma.mime, ma.width, ma.height, ma.storage_key,
	       (m.id <= pcp.last_read_message_id)
	from messages m
	join conversations c on c.id = m.conversation_id
	join conversation_participants pcp on pcp.conversation_id = m.conversation_id
	     and pcp.user_id = case when m.sender_id = c.user_lo then c.user_hi else c.user_lo end
	left join media_assets ma on ma.id = m.media_id `

func (a *API) scanMessages(ctx context.Context, rows pgx.Rows) ([]chatMessage, error) {
	defer rows.Close()
	out := []chatMessage{}
	for rows.Next() {
		var (
			m              chatMessage
			mid, mime, key *string
			width, height  *int32
		)
		if err := rows.Scan(&m.ID, &m.ConversationID, &m.SenderID, &m.Kind, &m.Body, &m.ClientMsgID, &m.CreatedAt,
			&mid, &mime, &width, &height, &key, &m.Read); err != nil {
			return nil, err
		}
		if mid != nil && mime != nil && key != nil && a.Media != nil {
			url, err := a.Media.DownloadURL(ctx, *mid, *key, time.Hour)
			if err != nil {
				return nil, err
			}
			m.Media = &chatMedia{ID: *mid, URL: url, Mime: *mime, Width: width, Height: height}
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// LoadMessageJSON is the realtime.MessageLoader: full JSON of one message for the WebSocket push.
func (a *API) LoadMessageJSON(ctx context.Context, id int64) (json.RawMessage, error) {
	rows, err := a.DB.Query(ctx, msgSelect+` where m.id=$1`, id)
	if err != nil {
		return nil, err
	}
	msgs, err := a.scanMessages(ctx, rows)
	if err != nil {
		return nil, err
	}
	if len(msgs) == 0 {
		return nil, pgx.ErrNoRows
	}
	return json.Marshal(msgs[0])
}

// ---- endpoints -----------------------------------------------------------------

// POST /v1/chat/conversations   {peer_public_id}   -> get or create the 1-on-1 thread
func (a *API) chatOpen(w http.ResponseWriter, r *http.Request) {
	var req struct {
		PeerPublicID int64 `json:"peer_public_id"`
	}
	if !decode(w, r, &req) {
		return
	}
	if !coinx.ValidPublicID(req.PeerPublicID) {
		writeErr(w, http.StatusBadRequest, "bad_request", "invalid peer_public_id")
		return
	}
	var (
		peerID, level         int64
		name, avatar, country string
	)
	err := a.DB.QueryRow(r.Context(), `
		select id, display_name, coalesce(avatar_url,''), coalesce(country_code,'BD'), level
		from users where public_id=$1`, req.PeerPublicID).Scan(&peerID, &name, &avatar, &country, &level)
	if err != nil {
		notFoundOr500(w, "chatOpen lookup", err, "user")
		return
	}
	var cid int64
	if err := withRetry(func() error {
		return a.DB.QueryRow(r.Context(), `select chat_open($1,$2)`, userID(r.Context()), peerID).Scan(&cid)
	}); err != nil {
		dbErr(w, "chat_open", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"conversation_id": cid, "peer": map[string]any{
		"id": peerID, "public_id": req.PeerPublicID, "display_name": name, "avatar_url": avatar, "country_code": country, "level": level}})
}

// GET /v1/chat/conversations?limit=&before_id=     inbox, newest first.  before_id = last_message_id of the last item
func (a *API) chatInbox(w http.ResponseWriter, r *http.Request) {
	uid := userID(r.Context())
	limit, before := paging(r)
	rows, err := a.DB.Query(r.Context(), `
		select conversation_id, unread_count, muted, last_message_id, peer_id, peer_public_id, peer_name,
		       coalesce(peer_avatar,''), coalesce(peer_country,'BD'), peer_level,
		       last_sender_id, last_kind::text, last_body, last_at, peer_last_read_message_id
		from v_chat_inbox
		where user_id=$1 and ($2::bigint=0 or last_message_id<$2::bigint)
		order by last_message_id desc limit $3`, uid, before, limit)
	if err != nil {
		dbErr(w, "chatInbox", err)
		return
	}
	defer rows.Close()
	type item struct {
		ConversationID int64          `json:"conversation_id"`
		UnreadCount    int            `json:"unread_count"`
		Muted          bool           `json:"muted"`
		Peer           map[string]any `json:"peer"`
		LastMessage    map[string]any `json:"last_message"`
		PeerLastRead   int64          `json:"peer_last_read_message_id"`
	}
	items := []item{}
	var next int64
	for rows.Next() {
		var (
			it                                  item
			lastID, peerID, peerPub, lastSender int64
			peerLevel                           int32
			peerName, avatar, country, lastKind string
			lastBody                            *string
			lastAt                              time.Time
		)
		if err := rows.Scan(&it.ConversationID, &it.UnreadCount, &it.Muted, &lastID, &peerID, &peerPub, &peerName,
			&avatar, &country, &peerLevel, &lastSender, &lastKind, &lastBody, &lastAt, &it.PeerLastRead); err != nil {
			dbErr(w, "chatInbox scan", err)
			return
		}
		it.Peer = map[string]any{"id": peerID, "public_id": peerPub, "display_name": peerName,
			"avatar_url": avatar, "country_code": country, "level": peerLevel}
		it.LastMessage = map[string]any{"id": lastID, "sender_id": lastSender, "kind": lastKind, "body": lastBody, "created_at": lastAt}
		items = append(items, it)
		next = lastID
	}
	if err := rows.Err(); err != nil {
		dbErr(w, "chatInbox rows", err)
		return
	}
	if len(items) < limit {
		next = 0
	}
	var total int64
	_ = a.DB.QueryRow(r.Context(), `
		select coalesce(sum(cp.unread_count) filter (where not cp.muted), 0)::bigint
		from conversation_participants cp where cp.user_id=$1`, uid).Scan(&total)
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "next_before_id": next, "total_unread": total})
}

// GET /v1/chat/conversations/{id}/messages?before_id=&after_id=&limit=
//
//	before_id : older page (scrolling up).  after_id : everything newer (catch up after a reconnect).
//	Items are always returned newest -> oldest.
func (a *API) chatMessages(w http.ResponseWriter, r *http.Request) {
	conv, ok := pathInt(w, r, "id")
	if !ok {
		return
	}
	uid := userID(r.Context())
	limit, before := paging(r)
	var after int64
	if v := r.URL.Query().Get("after_id"); v != "" {
		var err error
		if after, err = parseInt64(v); err != nil || after < 0 {
			writeErr(w, http.StatusBadRequest, "bad_request", "invalid after_id")
			return
		}
	}
	var cleared int64
	err := a.DB.QueryRow(r.Context(), `
		select cleared_before_id from conversation_participants where conversation_id=$1 and user_id=$2`, conv, uid).Scan(&cleared)
	if err != nil {
		notFoundOr500(w, "chatMessages access", err, "conversation")
		return
	}
	var rows pgx.Rows
	if after > 0 {
		rows, err = a.DB.Query(r.Context(), msgSelect+`
			where m.conversation_id=$1 and m.id>$2 and m.id>$3 order by m.id asc limit $4`, conv, cleared, after, limit)
	} else {
		rows, err = a.DB.Query(r.Context(), msgSelect+`
			where m.conversation_id=$1 and m.id>$2 and ($3::bigint=0 or m.id<$3::bigint) order by m.id desc limit $4`, conv, cleared, before, limit)
	}
	if err != nil {
		dbErr(w, "chatMessages", err)
		return
	}
	msgs, err := a.scanMessages(r.Context(), rows)
	if err != nil {
		dbErr(w, "chatMessages scan", err)
		return
	}
	if after > 0 { // fetched oldest-first to page forward; present newest-first like everything else
		for i, j := 0, len(msgs)-1; i < j; i, j = i+1, j-1 {
			msgs[i], msgs[j] = msgs[j], msgs[i]
		}
	}
	var next int64
	if after == 0 && len(msgs) == limit {
		next = msgs[len(msgs)-1].ID
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": msgs, "next_before_id": next, "has_more_after": after > 0 && len(msgs) == limit})
}

// POST /v1/chat/conversations/{id}/messages
//
//	{"kind":"text","body":"hi","client_msg_id":"<uuid>"}
//	{"kind":"image","media_id":"<uuid from /v1/chat/media>","body":"optional caption","client_msg_id":"<uuid>"}
//
// client_msg_id makes retries safe: sending the same id twice stores ONE message.
func (a *API) chatSend(w http.ResponseWriter, r *http.Request) {
	conv, ok := pathInt(w, r, "id")
	if !ok {
		return
	}
	var req struct {
		Kind        string `json:"kind"`
		Body        string `json:"body"`
		MediaID     string `json:"media_id"`
		ClientMsgID string `json:"client_msg_id"`
	}
	if !decode(w, r, &req) {
		return
	}
	if !coinx.ValidIdemKey(req.ClientMsgID) {
		writeErr(w, http.StatusBadRequest, "client_msg_id_required", "client_msg_id (8-64 chars, unique per message) is required")
		return
	}
	body, bodyOK := coinx.CleanMultiline(req.Body, 2000)
	if !bodyOK {
		writeErr(w, http.StatusBadRequest, "bad_request", "invalid message text")
		return
	}
	var media *string
	switch req.Kind {
	case "text":
		if body == "" {
			writeErr(w, http.StatusBadRequest, "empty_message", "message is empty")
			return
		}
	case "image":
		if !uuidRe.MatchString(req.MediaID) {
			writeErr(w, http.StatusBadRequest, "bad_request", "media_id is required for images")
			return
		}
		if len([]rune(body)) > 500 {
			writeErr(w, http.StatusBadRequest, "message_too_long", "caption is too long")
			return
		}
		media = &req.MediaID
	default:
		writeErr(w, http.StatusBadRequest, "bad_request", "kind must be text or image")
		return
	}
	var mid int64
	err := withRetry(func() error {
		return a.DB.QueryRow(r.Context(), `select chat_send($1,$2,$3::chat_msg_kind,$4,$5::uuid,$6)`,
			userID(r.Context()), conv, req.Kind, nullable(body), media, req.ClientMsgID).Scan(&mid)
	})
	if err != nil {
		dbErr(w, "chat_send", err)
		return
	}
	raw, err := a.LoadMessageJSON(r.Context(), mid)
	if err != nil {
		dbErr(w, "chatSend load", err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	_, _ = w.Write(raw)
}

// POST /v1/chat/conversations/{id}/read   {up_to_message_id?}    (default: everything)
func (a *API) chatRead(w http.ResponseWriter, r *http.Request) {
	conv, ok := pathInt(w, r, "id")
	if !ok {
		return
	}
	var req struct {
		UpTo *int64 `json:"up_to_message_id"`
	}
	if r.ContentLength != 0 && !decode(w, r, &req) {
		return
	}
	var mark int64
	if err := withRetry(func() error {
		return a.DB.QueryRow(r.Context(), `select chat_mark_read($1,$2,$3)`, userID(r.Context()), conv, req.UpTo).Scan(&mark)
	}); err != nil {
		dbErr(w, "chat_mark_read", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"last_read_message_id": mark})
}

// DELETE /v1/chat/conversations/{id}     delete the conversation FOR ME (the other person keeps it)
func (a *API) chatClear(w http.ResponseWriter, r *http.Request) {
	conv, ok := pathInt(w, r, "id")
	if !ok {
		return
	}
	if _, err := a.DB.Exec(r.Context(), `select chat_clear($1,$2)`, userID(r.Context()), conv); err != nil {
		dbErr(w, "chat_clear", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// PATCH /v1/chat/conversations/{id}   {muted: bool}
func (a *API) chatMute(w http.ResponseWriter, r *http.Request) {
	conv, ok := pathInt(w, r, "id")
	if !ok {
		return
	}
	var req struct {
		Muted *bool `json:"muted"`
	}
	if !decode(w, r, &req) {
		return
	}
	if req.Muted == nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "muted is required")
		return
	}
	if _, err := a.DB.Exec(r.Context(), `select chat_set_muted($1,$2,$3)`, userID(r.Context()), conv, *req.Muted); err != nil {
		dbErr(w, "chat_set_muted", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// GET /v1/chat/unread   badge count for the bottom-nav inbox icon (muted threads excluded)
func (a *API) chatUnread(w http.ResponseWriter, r *http.Request) {
	var total int64
	if err := a.DB.QueryRow(r.Context(), `
		select coalesce(sum(unread_count) filter (where not muted), 0)::bigint
		from conversation_participants where user_id=$1`, userID(r.Context())).Scan(&total); err != nil {
		dbErr(w, "chatUnread", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"total_unread": total})
}

var errBadInt = errors.New("bad int")

func parseInt64(s string) (int64, error) {
	var n int64
	if s == "" || len(s) > 18 {
		return 0, errBadInt
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return 0, errBadInt
		}
		n = n*10 + int64(c-'0')
	}
	return n, nil
}
