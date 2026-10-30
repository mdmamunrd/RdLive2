// Package realtime defines how the API pushes room events (gift animations,
// PK score updates, ...) to connected clients. The Rooms/PK module will provide
// a Redis- or Firebase-backed implementation; Nop is used until then.
package realtime

import "context"

type Event struct {
	Type string `json:"type"` // e.g. "gift"
	Data any    `json:"data"`
}

type Publisher interface {
	PublishRoom(ctx context.Context, roomID int64, e Event) error
}

type Nop struct{}

func (Nop) PublishRoom(context.Context, int64, Event) error { return nil }
