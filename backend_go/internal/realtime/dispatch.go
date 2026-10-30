package realtime

import (
	"context"
	"encoding/json"
	"log"
)

// Notification is one NOTIFY delivered by PostgreSQL.
type Notification struct{ Channel, Payload string }

// Channel names used by the SQL migrations.
const (
	ChannelRoom = "room_events" // 002: seats, moderation, PK, 003: gifts
	ChannelChat = "chat_events" // 004: messages, read receipts, typing
)

// MessageLoader returns the full JSON of one chat message (media URL included).
type MessageLoader func(ctx context.Context, messageID int64) (json.RawMessage, error)

// Dispatcher turns database notifications into WebSocket messages.
//
// Room events are small and forwarded as they are. Chat 'message' events carry only ids
// (pg_notify is capped at 8000 bytes), so they are loaded from the database by one worker
// goroutine, which also keeps messages of a conversation in order.
type Dispatcher struct {
	Hub  *Hub
	Load MessageLoader
	Logf func(format string, args ...any)

	chatQ chan chatJob
}

type chatJob struct {
	users []int64
	msgID int64
}

func NewDispatcher(h *Hub, load MessageLoader) *Dispatcher {
	return &Dispatcher{Hub: h, Load: load, Logf: log.Printf, chatQ: make(chan chatJob, 4096)}
}

// Handle routes one notification. It never blocks on the database.
func (d *Dispatcher) Handle(n Notification) {
	switch n.Channel {
	case ChannelRoom:
		d.handleRoom(n.Payload)
	case ChannelChat:
		d.handleChat(n.Payload)
	}
}

type roomPayload struct {
	RoomID int64           `json:"room_id"`
	Type   string          `json:"type"`
	Data   json.RawMessage `json:"data"`
}

func (d *Dispatcher) handleRoom(payload string) {
	var p roomPayload
	if err := json.Unmarshal([]byte(payload), &p); err != nil || p.RoomID == 0 || p.Type == "" {
		d.Logf("realtime: bad room event: %v payload=%.120s", err, payload)
		return
	}
	data := p.Data
	if len(data) == 0 {
		data = json.RawMessage("{}")
	}
	msg, _ := json.Marshal(struct {
		Type   string          `json:"type"`
		RoomID int64           `json:"room_id"`
		Event  string          `json:"event"`
		Data   json.RawMessage `json:"data"`
	}{"room_event", p.RoomID, p.Type, data})
	d.Hub.BroadcastRoom(p.RoomID, msg)

	switch p.Type {
	case "kicked", "left": // they got the event above; now stop sending them this room
		var k struct {
			UserID int64 `json:"user_id"`
		}
		if json.Unmarshal(data, &k) == nil && k.UserID != 0 {
			d.Hub.UnsubscribeUser(k.UserID, p.RoomID)
		}
	case "room_ended":
		d.Hub.CloseRoom(p.RoomID)
	}
}

type chatPayload struct {
	Type           string  `json:"type"`
	ConversationID int64   `json:"conversation_id"`
	MessageID      int64   `json:"message_id"`
	ReaderID       int64   `json:"reader_id"`
	UpToMessageID  int64   `json:"up_to_message_id"`
	UserID         int64   `json:"user_id"`
	Users          []int64 `json:"users"`
}

func (d *Dispatcher) handleChat(payload string) {
	var p chatPayload
	if err := json.Unmarshal([]byte(payload), &p); err != nil || len(p.Users) == 0 {
		d.Logf("realtime: bad chat event: %v payload=%.120s", err, payload)
		return
	}
	switch p.Type {
	case "message":
		select {
		case d.chatQ <- chatJob{users: p.Users, msgID: p.MessageID}:
		default:
			d.Logf("realtime: chat queue full, message %d not pushed (clients resync via REST)", p.MessageID)
		}
	case "read":
		msg, _ := json.Marshal(map[string]any{"type": "chat_read", "conversation_id": p.ConversationID,
			"reader_id": p.ReaderID, "up_to_message_id": p.UpToMessageID})
		d.sendUsers(p.Users, msg)
	case "typing":
		msg, _ := json.Marshal(map[string]any{"type": "typing", "conversation_id": p.ConversationID, "user_id": p.UserID})
		d.sendUsers(p.Users, msg)
	}
}

func (d *Dispatcher) sendUsers(users []int64, msg []byte) {
	for _, u := range users {
		d.Hub.SendUser(u, msg)
	}
}

// RunChat processes queued chat messages until ctx ends. Start it once, in its own goroutine.
func (d *Dispatcher) RunChat(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case job := <-d.chatQ:
			raw, err := d.Load(ctx, job.msgID)
			if err != nil {
				d.Logf("realtime: load message %d: %v", job.msgID, err)
				continue
			}
			msg, _ := json.Marshal(struct {
				Type    string          `json:"type"`
				Message json.RawMessage `json:"message"`
			}{"chat_message", raw})
			d.sendUsers(job.users, msg)
		}
	}
}

// Resync tells every client to reload its state: notifications may have been missed while
// the database connection of the listener was down.
func (d *Dispatcher) Resync() { d.Hub.BroadcastAll([]byte(`{"type":"resync"}`)) }
