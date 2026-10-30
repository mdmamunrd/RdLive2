package realtime

import (
	"errors"
	"sync"
	"sync/atomic"
)

// ErrTooManyConns is returned by Hub.Add when a user already has MaxPerUser sockets.
var ErrTooManyConns = errors.New("realtime: too many connections for this user")

// Client is one connected socket. The hub never blocks on a client: messages go into
// a bounded queue, and a client whose queue is full is considered too slow and is closed.
type Client struct {
	UserID int64
	send   chan []byte
	closer func()
	once   sync.Once
	rooms  map[int64]struct{} // guarded by Hub.mu
}

// NewClient creates a client with a queue of buf messages. closer must close the
// underlying socket (it is called at most once).
func NewClient(userID int64, buf int, closer func()) *Client {
	if buf <= 0 {
		buf = 64
	}
	return &Client{UserID: userID, send: make(chan []byte, buf), closer: closer, rooms: map[int64]struct{}{}}
}

// Send is the channel the socket writer goroutine drains.
func (c *Client) Send() <-chan []byte { return c.send }

// Close closes the socket (idempotent).
func (c *Client) Close() {
	c.once.Do(func() {
		if c.closer != nil {
			c.closer()
		}
	})
}

// Enqueue queues a message for this client without blocking. false = queue full.
func (c *Client) Enqueue(msg []byte) bool {
	select {
	case c.send <- msg:
		return true
	default:
		return false
	}
}

// Hub tracks connected clients, their room subscriptions and per-user fan-out.
type Hub struct {
	MaxPerUser int // 0 = unlimited

	mu    sync.RWMutex
	users map[int64]map[*Client]struct{}
	rooms map[int64]map[*Client]struct{}

	dropped atomic.Int64 // slow clients disconnected
}

func NewHub(maxPerUser int) *Hub {
	return &Hub{MaxPerUser: maxPerUser, users: map[int64]map[*Client]struct{}{}, rooms: map[int64]map[*Client]struct{}{}}
}

func (h *Hub) Add(c *Client) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	set := h.users[c.UserID]
	if h.MaxPerUser > 0 && len(set) >= h.MaxPerUser {
		return ErrTooManyConns
	}
	if set == nil {
		set = map[*Client]struct{}{}
		h.users[c.UserID] = set
	}
	set[c] = struct{}{}
	return nil
}

// Remove drops the client and all of its subscriptions.
func (h *Hub) Remove(c *Client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.removeLocked(c)
}

func (h *Hub) removeLocked(c *Client) {
	if set := h.users[c.UserID]; set != nil {
		delete(set, c)
		if len(set) == 0 {
			delete(h.users, c.UserID)
		}
	}
	for room := range c.rooms {
		h.unsubLocked(c, room)
	}
}

func (h *Hub) Subscribe(c *Client, room int64) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, ok := h.users[c.UserID][c]; !ok {
		return // already removed
	}
	set := h.rooms[room]
	if set == nil {
		set = map[*Client]struct{}{}
		h.rooms[room] = set
	}
	set[c] = struct{}{}
	c.rooms[room] = struct{}{}
}

func (h *Hub) Unsubscribe(c *Client, room int64) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.unsubLocked(c, room)
}

func (h *Hub) unsubLocked(c *Client, room int64) {
	if set := h.rooms[room]; set != nil {
		delete(set, c)
		if len(set) == 0 {
			delete(h.rooms, room)
		}
	}
	delete(c.rooms, room)
}

// UnsubscribeUser removes every socket of user from room (kicked / banned).
func (h *Hub) UnsubscribeUser(user, room int64) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for c := range h.users[user] {
		h.unsubLocked(c, room)
	}
}

// CloseRoom drops all subscriptions of a room (the room ended).
func (h *Hub) CloseRoom(room int64) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for c := range h.rooms[room] {
		delete(c.rooms, room)
	}
	delete(h.rooms, room)
}

func (h *Hub) deliver(targets []*Client, msg []byte) int {
	n := 0
	var slow []*Client
	for _, c := range targets {
		if c.Enqueue(msg) {
			n++
		} else {
			slow = append(slow, c)
		}
	}
	for _, c := range slow {
		h.dropped.Add(1)
		h.Remove(c)
		c.Close()
	}
	return n
}

func snapshot(set map[*Client]struct{}) []*Client {
	out := make([]*Client, 0, len(set))
	for c := range set {
		out = append(out, c)
	}
	return out
}

// BroadcastRoom sends msg to everyone subscribed to room; returns how many received it.
func (h *Hub) BroadcastRoom(room int64, msg []byte) int {
	h.mu.RLock()
	targets := snapshot(h.rooms[room])
	h.mu.RUnlock()
	return h.deliver(targets, msg)
}

// SendUser sends msg to all sockets of one user (phone + tablet ...).
func (h *Hub) SendUser(user int64, msg []byte) int {
	h.mu.RLock()
	targets := snapshot(h.users[user])
	h.mu.RUnlock()
	return h.deliver(targets, msg)
}

// BroadcastAll sends msg to every connected client (e.g. "resync").
func (h *Hub) BroadcastAll(msg []byte) int {
	h.mu.RLock()
	var targets []*Client
	for _, set := range h.users {
		for c := range set {
			targets = append(targets, c)
		}
	}
	h.mu.RUnlock()
	return h.deliver(targets, msg)
}

// Stats is for /healthz-style diagnostics.
func (h *Hub) Stats() (clients, subscribedRooms int, droppedSlow int64) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, set := range h.users {
		clients += len(set)
	}
	return clients, len(h.rooms), h.dropped.Load()
}

func (h *Hub) IsSubscribed(c *Client, room int64) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	_, ok := c.rooms[room]
	return ok
}

// RoomCount is how many rooms the client is subscribed to (the API caps it).
func (h *Hub) RoomCount(c *Client) int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(c.rooms)
}
