package api

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"rdlive/internal/realtime"
	"rdlive/internal/ws"
)

// GET /v1/ws  — one WebSocket per device for ALL realtime traffic (room events + 1-on-1 chat).
//
// Protocol (JSON text frames):
//
//	client -> {"op":"auth","token":"<access token>"}          must be the FIRST frame, within 10 s
//	server -> {"type":"ready","user_id":123}
//	client -> {"op":"subscribe_room","room_id":5}             only if you are a member of the room
//	client -> {"op":"unsubscribe_room","room_id":5}
//	client -> {"op":"typing","conversation_id":9}             throttled; delivered to the other person
//	client -> {"op":"ping"}                                   server -> {"type":"pong"}
//	server -> {"type":"ack","op":"subscribe_room","room_id":5}  /  {"type":"error","op":..,"code":..,"message":..}
//	server -> {"type":"room_event","room_id":5,"event":"seats_changed","data":{...}}
//	server -> {"type":"chat_message","message":{...}}   {"type":"chat_read",...}   {"type":"typing",...}
//	server -> {"type":"resync"}   events may have been missed: reload the room snapshot / inbox over REST
//
// The token travels in the first frame, never in the URL, so it does not end up in access logs.
const (
	wsAuthWindow   = 10 * time.Second
	wsReadTimeout  = 75 * time.Second // client should ping every ~30 s
	wsPingEvery    = 25 * time.Second
	wsRecheckEvery = 5 * time.Minute // banned / suspended users are dropped within 5 minutes
	wsMaxMessage   = 4 << 10
	wsMaxRooms     = 3
	wsQueue        = 128
)

func (a *API) wsOriginOK(r *http.Request) bool {
	o := r.Header.Get("Origin")
	for _, allowed := range a.Cfg.PortalOrigins {
		if o == allowed {
			return true
		}
	}
	i := strings.Index(o, "://")
	return i >= 0 && strings.EqualFold(o[i+3:], r.Host)
}

type wsIn struct {
	Op             string `json:"op"`
	Token          string `json:"token"`
	RoomID         int64  `json:"room_id"`
	ConversationID int64  `json:"conversation_id"`
}

func wsJSON(v any) []byte { b, _ := json.Marshal(v); return b }

func (a *API) wsHandler(w http.ResponseWriter, r *http.Request) {
	conn, err := ws.Upgrade(w, r, ws.Options{
		MaxMessage: wsMaxMessage, ReadTimeout: wsAuthWindow, CheckOrigin: a.wsOriginOK,
	})
	if err != nil {
		return // Upgrade already answered
	}
	defer conn.Close(ws.CloseNormal, "")

	// ---- 1. authenticate (first frame, short window) --------------------------------
	op, data, err := conn.ReadMessage()
	var first wsIn
	if err != nil || op != ws.OpText || json.Unmarshal(data, &first) != nil || first.Op != "auth" {
		_ = conn.WriteText(wsJSON(map[string]any{"type": "error", "code": "auth_required", "message": `first frame must be {"op":"auth","token":"..."}`}))
		_ = conn.Close(ws.ClosePolicyViolation, "auth required")
		return
	}
	uid, _, err := a.Tokens.Parse(first.Token)
	if err != nil || !a.userActive(r.Context(), uid) {
		_ = conn.WriteText(wsJSON(map[string]any{"type": "error", "code": "unauthorized", "message": "invalid or expired token"}))
		_ = conn.Close(ws.ClosePolicyViolation, "unauthorized")
		return
	}
	conn.SetReadTimeout(wsReadTimeout)

	// Close in a goroutine: conn.Close waits for the write lock, and a slow client's writer may hold it
	// for up to the write timeout. The hub (and so every other user's events) must never wait for that.
	client := realtime.NewClient(uid, wsQueue, func() { go func() { _ = conn.Close(ws.CloseGoingAway, "slow consumer") }() })
	if err := a.Hub.Add(client); err != nil {
		_ = conn.WriteText(wsJSON(map[string]any{"type": "error", "code": "too_many_connections", "message": "too many open connections"}))
		_ = conn.Close(ws.ClosePolicyViolation, "too many connections")
		return
	}
	defer a.Hub.Remove(client)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	client.Enqueue(wsJSON(map[string]any{"type": "ready", "user_id": uid}))

	// ---- 2. single writer goroutine: queue + ping + periodic account re-check ---------
	go func() {
		ping := time.NewTicker(wsPingEvery)
		recheck := time.NewTicker(wsRecheckEvery)
		defer ping.Stop()
		defer recheck.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case msg := <-client.Send():
				if conn.WriteText(msg) != nil {
					_ = conn.Close(ws.CloseGoingAway, "")
					return
				}
			case <-ping.C:
				if conn.WritePing() != nil {
					_ = conn.Close(ws.CloseGoingAway, "")
					return
				}
			case <-recheck.C:
				if !a.userActive(ctx, uid) {
					_ = conn.Close(ws.ClosePolicyViolation, "account blocked")
					return
				}
			}
		}
	}()

	// ---- 3. read loop ----------------------------------------------------------------
	lastTyping := map[int64]time.Time{}
	reply := func(v any) { client.Enqueue(wsJSON(v)) }
	fail := func(op, code, msg string) {
		reply(map[string]any{"type": "error", "op": op, "code": code, "message": msg})
	}
	for {
		op, data, err := conn.ReadMessage()
		if err != nil {
			return
		}
		if op != ws.OpText {
			fail("", "bad_request", "text frames only")
			continue
		}
		var in wsIn
		if json.Unmarshal(data, &in) != nil {
			fail("", "bad_request", "invalid JSON")
			continue
		}
		cctx, ccancel := context.WithTimeout(ctx, 5*time.Second)
		switch in.Op {
		case "ping":
			reply(map[string]any{"type": "pong"})

		case "subscribe_room":
			var member bool
			err := a.DB.QueryRow(cctx, `
				select exists(select 1 from room_members m join live_rooms r on r.id = m.room_id
				               where m.room_id=$1 and m.user_id=$2 and m.left_at is null and r.status='live')`,
				in.RoomID, uid).Scan(&member)
			switch {
			case err != nil:
				fail(in.Op, "internal", "try again")
			case !member:
				fail(in.Op, "not_in_room", "join the room first (POST /v1/rooms/{id}/join)")
			case a.Hub.RoomCount(client) >= wsMaxRooms && !a.Hub.IsSubscribed(client, in.RoomID):
				fail(in.Op, "too_many_rooms", "too many subscribed rooms")
			default:
				a.Hub.Subscribe(client, in.RoomID)
				reply(map[string]any{"type": "ack", "op": in.Op, "room_id": in.RoomID})
			}

		case "unsubscribe_room":
			a.Hub.Unsubscribe(client, in.RoomID)
			reply(map[string]any{"type": "ack", "op": in.Op, "room_id": in.RoomID})

		case "typing":
			if t, ok := lastTyping[in.ConversationID]; ok && time.Since(t) < 2*time.Second {
				break
			}
			lastTyping[in.ConversationID] = time.Now()
			if len(lastTyping) > 50 {
				lastTyping = map[int64]time.Time{in.ConversationID: time.Now()}
			}
			if err := a.sendTyping(cctx, uid, in.ConversationID); err != nil {
				fail(in.Op, "conversation_not_found", "conversation not found")
			}

		default:
			fail(in.Op, "unknown_op", "unknown op")
		}
		ccancel()
	}
}

// userActive: a banned / suspended account loses its socket.
func (a *API) userActive(ctx context.Context, uid int64) bool {
	var status string
	if err := a.DB.QueryRow(ctx, `select status::text from users where id=$1`, uid).Scan(&status); err != nil {
		return false
	}
	return status == "active"
}

// sendTyping relays "typing…" through PostgreSQL so it also works with several API replicas.
func (a *API) sendTyping(ctx context.Context, uid, conv int64) error {
	var peer int64
	if err := a.DB.QueryRow(ctx, `
		select case when user_lo=$2 then user_hi else user_lo end
		from conversations where id=$1 and $2 in (user_lo,user_hi) and not _users_blocked(user_lo,user_hi)`, conv, uid).Scan(&peer); err != nil {
		return err
	}
	payload := string(wsJSON(map[string]any{"type": "typing", "conversation_id": conv, "user_id": uid, "users": []int64{peer}}))
	_, err := a.DB.Exec(ctx, `select pg_notify('chat_events', $1)`, payload)
	return err
}
