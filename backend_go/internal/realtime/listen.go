package realtime

import (
	"context"
	"time"
)

// Backoff bounds (variables so tests can shrink them).
var (
	backoffBase = time.Second
	backoffMax  = 30 * time.Second
)

// Source blocks and delivers notifications until it fails or ctx ends. onReady is called once
// LISTEN is active. The pgx implementation lives in internal/pgnotify (it needs the driver).
type Source interface {
	Listen(ctx context.Context, channels []string, onReady func(), handle func(Notification)) error
}

// RunListener keeps a Source alive: on failure it waits (1s, 2s, 4s ... 30s) and reconnects.
// After every RE-connection onResync is called, because events may have been lost in the gap.
// Returns only when ctx is cancelled.
func RunListener(ctx context.Context, src Source, channels []string, handle func(Notification), onResync func(), logf func(string, ...any)) {
	backoff := backoffBase
	first := true
	for ctx.Err() == nil {
		ready := false
		err := src.Listen(ctx, channels, func() {
			ready = true
			if !first && onResync != nil {
				onResync()
			}
			first = false
			backoff = backoffBase
		}, handle)
		if ctx.Err() != nil {
			return
		}
		logf("realtime: listener stopped (ready=%v): %v; reconnecting in %s", ready, err, backoff)
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		if backoff *= 2; backoff > backoffMax {
			backoff = backoffMax
		}
	}
}
