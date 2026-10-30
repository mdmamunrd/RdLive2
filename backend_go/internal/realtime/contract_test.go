package realtime

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

// testdata/pg_payloads.tsv holds NOTIFY payloads captured from a real PostgreSQL 16 running the
// 002/003/004 migrations (room create/join, seats, mute, gifts, PK, kick, leave, chat, room end).
// Replaying them here proves the Go dispatcher understands exactly what the database emits.
// Regenerate the file after changing a pg_notify payload in SQL.
func loadPayloads(t *testing.T) []Notification {
	t.Helper()
	f, err := os.Open("testdata/pg_payloads.tsv")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	var out []Notification
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64<<10), 1<<20)
	for sc.Scan() {
		ch, pl, ok := strings.Cut(sc.Text(), "\t")
		if !ok {
			t.Fatalf("bad fixture line %q", sc.Text())
		}
		out = append(out, Notification{Channel: ch, Payload: pl})
	}
	if len(out) < 20 {
		t.Fatalf("fixture too small: %d", len(out))
	}
	return out
}

// drainAll returns every queued message of c, decoded.
func drainAll(c *Client) []map[string]any {
	var out []map[string]any
	for {
		select {
		case b := <-c.Send():
			var m map[string]any
			_ = json.Unmarshal(b, &m)
			out = append(out, m)
		default:
			return out
		}
	}
}

func events(msgs []map[string]any, typ string) []map[string]any {
	var out []map[string]any
	for _, m := range msgs {
		if m["type"] == typ {
			out = append(out, m)
		}
	}
	return out
}

func lastEvent(msgs []map[string]any) string {
	ev := events(msgs, "room_event")
	if len(ev) == 0 {
		return ""
	}
	return ev[len(ev)-1]["event"].(string)
}

func TestRealPostgresPayloadsThroughDispatcher(t *testing.T) {
	payloads := loadPayloads(t)

	h := NewHub(0)
	var loadedIDs []int64
	d := NewDispatcher(h, func(_ context.Context, id int64) (json.RawMessage, error) {
		loadedIDs = append(loadedIDs, id) // single RunChat goroutine => no race
		return json.RawMessage(fmt.Sprintf(`{"id":%d,"body":"হ্যালো 👋"}`, id)), nil
	})
	d.Logf = func(f string, a ...any) { t.Errorf("dispatcher complained about a REAL payload: "+f, a...) }

	obs, _ := newC(99, 256) // watches both rooms (like an audience member in each)
	u3, _ := newC(3, 256)   // leaves room 1, chats
	u4, _ := newC(4, 256)   // is kicked from room 1, chats
	for _, c := range []*Client{obs, u3, u4} {
		if err := h.Add(c); err != nil {
			t.Fatal(err)
		}
	}
	h.Subscribe(obs, 1)
	h.Subscribe(obs, 2)
	h.Subscribe(u3, 1)
	h.Subscribe(u4, 1)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go d.RunChat(ctx)

	for _, n := range payloads {
		d.Handle(n)
	}
	// chat messages are loaded asynchronously
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if len(h.users[3]) > 0 && len(u3.send) >= 1 && len(u4.send) >= 1 {
			time.Sleep(50 * time.Millisecond)
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	o, a3, a4 := drainAll(obs), drainAll(u3), drainAll(u4)

	// ---- room events -------------------------------------------------------------------
	gifts := events(o, "room_event")
	var diamonds []float64
	pkRooms := map[float64]bool{}
	var sawEnded bool
	for _, m := range gifts {
		switch m["event"] {
		case "gift":
			diamonds = append(diamonds, m["data"].(map[string]any)["receiver_today_diamonds"].(float64))
		case "pk_score":
			pkRooms[m["room_id"].(float64)] = true
		case "room_ended":
			sawEnded = true
		}
	}
	if len(diamonds) != 2 || diamonds[0] != 14 || diamonds[1] != 21 {
		t.Errorf("gift events with the host's running daily total: got %v, want [14 21]", diamonds)
	}
	if !pkRooms[1] || !pkRooms[2] {
		t.Errorf("PK score must reach the audience of BOTH rooms: %v", pkRooms)
	}
	if !sawEnded || h.IsSubscribed(obs, 1) {
		t.Errorf("room_ended must be delivered, then room 1 subscriptions closed (ended=%v subscribed=%v)", sawEnded, h.IsSubscribed(obs, 1))
	}
	if !h.IsSubscribed(obs, 2) {
		t.Error("room 2 never ended; its subscription must stay")
	}

	// ---- kick / leave stop the stream for that person only ------------------------------
	if got := lastEvent(a4); got != "kicked" {
		t.Errorf("kicked user's LAST room event must be 'kicked', got %q", got)
	}
	if got := lastEvent(a3); got != "left" {
		t.Errorf("user who left: LAST room event must be 'left', got %q", got)
	}
	if h.IsSubscribed(u4, 1) || h.IsSubscribed(u3, 1) {
		t.Error("kicked / left users must be unsubscribed")
	}

	// ---- chat ------------------------------------------------------------------------------
	if len(loadedIDs) != 1 || loadedIDs[0] != 1 {
		t.Errorf("chat message must be loaded by id from the payload: %v", loadedIDs)
	}
	for name, msgs := range map[string][]map[string]any{"user 3": a3, "user 4": a4} {
		cm := events(msgs, "chat_message")
		if len(cm) != 1 {
			t.Errorf("%s: want 1 chat_message, got %d", name, len(cm))
			continue
		}
		if cm[0]["message"].(map[string]any)["body"] != "হ্যালো 👋" {
			t.Errorf("%s: message body mangled: %v", name, cm[0])
		}
	}
	rd := events(a3, "chat_read")
	if len(rd) != 1 || rd[0]["reader_id"].(float64) != 4 || rd[0]["up_to_message_id"].(float64) != 1 {
		t.Errorf("sender (user 3) must get the read receipt from user 4: %v", rd)
	}
	if len(events(a4, "chat_read")) != 0 {
		t.Error("the reader must not receive their own read receipt")
	}
	if len(events(o, "chat_message"))+len(events(o, "chat_read")) != 0 {
		t.Error("a bystander must never receive other people's chat traffic")
	}
}
