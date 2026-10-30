package realtime

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func newC(user int64, buf int) (*Client, *atomic.Int32) {
	var closed atomic.Int32
	return NewClient(user, buf, func() { closed.Add(1) }), &closed
}

func recv(t *testing.T, c *Client) map[string]any {
	t.Helper()
	select {
	case b := <-c.Send():
		var m map[string]any
		if err := json.Unmarshal(b, &m); err != nil {
			t.Fatalf("bad json %q: %v", b, err)
		}
		return m
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for a message")
		return nil
	}
}

func none(t *testing.T, c *Client) {
	t.Helper()
	select {
	case b := <-c.Send():
		t.Fatalf("unexpected message: %s", b)
	case <-time.After(30 * time.Millisecond):
	}
}

func TestHubRoomIsolation(t *testing.T) {
	h := NewHub(0)
	a, _ := newC(1, 8)
	b, _ := newC(2, 8)
	out, _ := newC(3, 8)
	for _, c := range []*Client{a, b, out} {
		if err := h.Add(c); err != nil {
			t.Fatal(err)
		}
	}
	h.Subscribe(a, 10)
	h.Subscribe(b, 10)
	h.Subscribe(out, 11)
	if n := h.BroadcastRoom(10, []byte(`{"x":1}`)); n != 2 {
		t.Fatalf("delivered to %d, want 2", n)
	}
	recv(t, a)
	recv(t, b)
	none(t, out) // a different room must never leak
	h.Unsubscribe(b, 10)
	h.BroadcastRoom(10, []byte(`{"x":2}`))
	recv(t, a)
	none(t, b)
}

func TestHubSubscribeAfterRemoveIsIgnored(t *testing.T) {
	h := NewHub(0)
	c, _ := newC(1, 4)
	_ = h.Add(c)
	h.Remove(c)
	h.Subscribe(c, 5) // racing a disconnect must not resurrect the client
	if n := h.BroadcastRoom(5, []byte(`{}`)); n != 0 {
		t.Fatal("removed client still receives")
	}
	if cl, rooms, _ := h.Stats(); cl != 0 || rooms != 0 {
		t.Fatalf("leak: clients=%d rooms=%d", cl, rooms)
	}
}

func TestHubMaxPerUserAndMultiDevice(t *testing.T) {
	h := NewHub(2)
	c1, _ := newC(7, 4)
	c2, _ := newC(7, 4)
	c3, _ := newC(7, 4)
	if h.Add(c1) != nil || h.Add(c2) != nil {
		t.Fatal("first two must be accepted")
	}
	if !errors.Is(h.Add(c3), ErrTooManyConns) {
		t.Fatal("third connection must be refused")
	}
	if n := h.SendUser(7, []byte(`{"p":1}`)); n != 2 {
		t.Fatalf("SendUser reached %d devices, want 2", n)
	}
	h.Remove(c1)
	if h.Add(c3) != nil {
		t.Fatal("slot should be free after a disconnect")
	}
}

func TestHubSlowClientIsDroppedOnce(t *testing.T) {
	h := NewHub(0)
	slow, closed := newC(1, 2)
	fast, _ := newC(2, 64)
	_ = h.Add(slow)
	_ = h.Add(fast)
	h.Subscribe(slow, 1)
	h.Subscribe(fast, 1)
	for i := 0; i < 5; i++ { // nobody drains `slow`
		h.BroadcastRoom(1, []byte(fmt.Sprintf(`{"i":%d}`, i)))
	}
	if closed.Load() != 1 {
		t.Fatalf("slow client closer called %d times, want exactly 1", closed.Load())
	}
	if _, _, dropped := h.Stats(); dropped != 1 {
		t.Fatalf("dropped=%d", dropped)
	}
	for i := 0; i < 5; i++ { // the healthy client got everything, in order
		if m := recv(t, fast); int(m["i"].(float64)) != i {
			t.Fatalf("out of order: %v", m)
		}
	}
}

func TestHubConcurrentUse(t *testing.T) {
	h := NewHub(0)
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			c, _ := newC(int64(i%5), 1024)
			_ = h.Add(c)
			for j := 0; j < 50; j++ {
				h.Subscribe(c, int64(j%7))
				h.BroadcastRoom(int64(j%7), []byte(`{}`))
				h.SendUser(int64(i%5), []byte(`{}`))
				if j%10 == 0 {
					h.Unsubscribe(c, int64(j%7))
				}
			}
			h.Remove(c)
		}(i)
	}
	wg.Wait()
	if cl, rooms, _ := h.Stats(); cl != 0 || rooms != 0 {
		t.Fatalf("leak: clients=%d rooms=%d", cl, rooms)
	}
}

func TestDispatcherRoomEvent(t *testing.T) {
	h := NewHub(0)
	d := NewDispatcher(h, nil)
	d.Logf = func(string, ...any) {}
	c, _ := newC(1, 8)
	other, _ := newC(2, 8)
	_ = h.Add(c)
	_ = h.Add(other)
	h.Subscribe(c, 42)
	h.Subscribe(other, 99)

	d.Handle(Notification{ChannelRoom, `{"room_id":42,"type":"seats_changed","data":{}}`})
	m := recv(t, c)
	if m["type"] != "room_event" || m["event"] != "seats_changed" || m["room_id"].(float64) != 42 {
		t.Fatalf("bad envelope: %v", m)
	}
	none(t, other)

	d.Handle(Notification{ChannelRoom, `{"room_id":42,"type":"gift","data":{"gift_tx_id":9,"receiver_today_diamonds":1064}}`})
	m = recv(t, c)
	if m["data"].(map[string]any)["receiver_today_diamonds"].(float64) != 1064 {
		t.Fatalf("data not forwarded: %v", m)
	}

	// malformed payloads are dropped, never panic
	for _, bad := range []string{``, `not json`, `{}`, `{"room_id":0,"type":"x"}`, `{"room_id":1}`} {
		d.Handle(Notification{ChannelRoom, bad})
	}
	none(t, c)
}

func TestDispatcherKickedUserStopsReceiving(t *testing.T) {
	h := NewHub(0)
	d := NewDispatcher(h, nil)
	victim, _ := newC(5, 8)
	rest, _ := newC(6, 8)
	_ = h.Add(victim)
	_ = h.Add(rest)
	h.Subscribe(victim, 1)
	h.Subscribe(rest, 1)
	d.Handle(Notification{ChannelRoom, `{"room_id":1,"type":"kicked","data":{"user_id":5,"banned":true}}`})
	if m := recv(t, victim); m["event"] != "kicked" { // the victim is told...
		t.Fatalf("victim must see the kick: %v", m)
	}
	recv(t, rest)
	d.Handle(Notification{ChannelRoom, `{"room_id":1,"type":"seats_changed","data":{}}`}) // ...and then hears nothing more
	none(t, victim)
	recv(t, rest)
}

func TestDispatcherRoomEndedClosesSubscriptions(t *testing.T) {
	h := NewHub(0)
	d := NewDispatcher(h, nil)
	c, _ := newC(1, 8)
	_ = h.Add(c)
	h.Subscribe(c, 3)
	d.Handle(Notification{ChannelRoom, `{"room_id":3,"type":"room_ended","data":{}}`})
	recv(t, c)
	if h.IsSubscribed(c, 3) {
		t.Fatal("still subscribed to an ended room")
	}
}

func TestDispatcherChatMessageOrderAndTargets(t *testing.T) {
	h := NewHub(0)
	var mu sync.Mutex
	var loaded []int64
	d := NewDispatcher(h, func(_ context.Context, id int64) (json.RawMessage, error) {
		mu.Lock()
		loaded = append(loaded, id)
		mu.Unlock()
		if id == 13 {
			return nil, errors.New("db down")
		}
		return json.RawMessage(fmt.Sprintf(`{"id":%d,"body":"hi"}`, id)), nil
	})
	d.Logf = func(string, ...any) {}
	alice, _ := newC(1, 16)
	bob, _ := newC(2, 16)
	eve, _ := newC(3, 16)
	for _, c := range []*Client{alice, bob, eve} {
		_ = h.Add(c)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go d.RunChat(ctx)

	for _, id := range []int{11, 12, 13, 14} {
		d.Handle(Notification{ChannelChat, fmt.Sprintf(`{"type":"message","conversation_id":5,"message_id":%d,"users":[1,2]}`, id)})
	}
	for _, want := range []float64{11, 12, 14} { // 13 failed to load: skipped, the rest still flow, in order
		for _, c := range []*Client{alice, bob} {
			m := recv(t, c)
			if m["type"] != "chat_message" || m["message"].(map[string]any)["id"].(float64) != want {
				t.Fatalf("user got %v, want message %v", m, want)
			}
		}
	}
	none(t, eve) // a third party never sees a private message
}

func TestDispatcherReadAndTyping(t *testing.T) {
	h := NewHub(0)
	d := NewDispatcher(h, nil)
	alice, _ := newC(1, 8)
	bob, _ := newC(2, 8)
	_ = h.Add(alice)
	_ = h.Add(bob)
	d.Handle(Notification{ChannelChat, `{"type":"read","conversation_id":5,"reader_id":2,"up_to_message_id":77,"users":[1]}`})
	m := recv(t, alice)
	if m["type"] != "chat_read" || m["up_to_message_id"].(float64) != 77 || m["reader_id"].(float64) != 2 {
		t.Fatalf("bad read event: %v", m)
	}
	none(t, bob)
	d.Handle(Notification{ChannelChat, `{"type":"typing","conversation_id":5,"user_id":1,"users":[2]}`})
	if m = recv(t, bob); m["type"] != "typing" || m["user_id"].(float64) != 1 {
		t.Fatalf("bad typing event: %v", m)
	}
	none(t, alice)
}

func TestDispatcherResync(t *testing.T) {
	h := NewHub(0)
	d := NewDispatcher(h, nil)
	a, _ := newC(1, 4)
	b, _ := newC(2, 4)
	_ = h.Add(a)
	_ = h.Add(b)
	d.Resync()
	if recv(t, a)["type"] != "resync" || recv(t, b)["type"] != "resync" {
		t.Fatal("all clients must be told to resync")
	}
}

// ---- listener loop ---------------------------------------------------------

type fakeSrc struct {
	mu    sync.Mutex
	calls int
	plan  []error // per call: error to return after "ready"; nil = block until ctx ends
	emit  []Notification
}

func (f *fakeSrc) Listen(ctx context.Context, ch []string, onReady func(), handle func(Notification)) error {
	f.mu.Lock()
	i := f.calls
	f.calls++
	f.mu.Unlock()
	if i < len(f.plan) && f.plan[i] != nil && f.plan[i].Error() == "connect failed" {
		return f.plan[i] // fails before ready
	}
	onReady()
	for _, n := range f.emit {
		handle(n)
	}
	if i < len(f.plan) && f.plan[i] != nil {
		return f.plan[i]
	}
	<-ctx.Done()
	return ctx.Err()
}

func TestRunListenerReconnectsAndResyncs(t *testing.T) {
	oldB, oldM := backoffBase, backoffMax
	backoffBase, backoffMax = 5*time.Millisecond, 20*time.Millisecond
	defer func() { backoffBase, backoffMax = oldB, oldM }()

	src := &fakeSrc{
		plan: []error{errors.New("connection reset"), errors.New("connect failed"), nil},
		emit: []Notification{{ChannelRoom, "x"}},
	}
	var got atomic.Int32
	var resyncs atomic.Int32
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		RunListener(ctx, src, []string{ChannelRoom}, func(Notification) { got.Add(1) }, func() { resyncs.Add(1) }, func(string, ...any) {})
		close(done)
	}()
	deadline := time.After(2 * time.Second)
	for {
		src.mu.Lock()
		c := src.calls
		src.mu.Unlock()
		if c >= 3 && got.Load() >= 2 {
			break
		}
		select {
		case <-deadline:
			t.Fatalf("calls=%d got=%d", c, got.Load())
		case <-time.After(5 * time.Millisecond):
		}
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("RunListener did not stop on cancel")
	}
	// call 1 ready (first, no resync) -> dropped; call 2 failed before ready; call 3 ready => exactly ONE resync
	if resyncs.Load() != 1 {
		t.Fatalf("resyncs=%d, want 1 (only after a successful RE-connection)", resyncs.Load())
	}
}

func TestDispatcherLeftUserStopsReceiving(t *testing.T) {
	h := NewHub(0)
	d := NewDispatcher(h, nil)
	leaver, _ := newC(7, 8)
	stay, _ := newC(8, 8)
	_ = h.Add(leaver)
	_ = h.Add(stay)
	h.Subscribe(leaver, 2)
	h.Subscribe(stay, 2)
	d.Handle(Notification{ChannelRoom, `{"room_id":2,"type":"left","data":{"user_id":7}}`})
	recv(t, leaver)
	recv(t, stay) // everyone is told someone left
	d.Handle(Notification{ChannelRoom, `{"room_id":2,"type":"gift","data":{"coins_spent":500}}`})
	none(t, leaver) // someone who left the room must not keep receiving its gifts
	recv(t, stay)
}
