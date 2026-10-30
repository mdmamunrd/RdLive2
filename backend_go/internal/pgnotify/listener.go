// Package pgnotify is the PostgreSQL side of internal/realtime: one dedicated connection
// that LISTENs on the room_events / chat_events channels.
package pgnotify

import (
	"context"
	"fmt"
	"net"
	"time"

	"github.com/jackc/pgx/v5"

	"rdlive/internal/realtime"
)

// Listener implements realtime.Source. It uses its own connection (not the pool), because a
// LISTENing connection must stay open and cannot be shared with normal queries.
type Listener struct{ URL string }

var _ realtime.Source = (*Listener)(nil)

func (l *Listener) Listen(ctx context.Context, channels []string, onReady func(), handle func(realtime.Notification)) error {
	cfg, err := pgx.ParseConfig(l.URL)
	if err != nil {
		return fmt.Errorf("pgnotify: parse url: %w", err)
	}
	// TCP keepalive so a silently dead connection is noticed within about a minute.
	cfg.DialFunc = (&net.Dialer{Timeout: 10 * time.Second, KeepAlive: 20 * time.Second}).DialContext
	conn, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		return fmt.Errorf("pgnotify: connect: %w", err)
	}
	defer conn.Close(context.Background())

	for _, ch := range channels {
		if _, err := conn.Exec(ctx, "LISTEN "+pgx.Identifier{ch}.Sanitize()); err != nil {
			return fmt.Errorf("pgnotify: LISTEN %s: %w", ch, err)
		}
	}
	onReady()
	for {
		n, err := conn.WaitForNotification(ctx)
		if err != nil {
			return err
		}
		handle(realtime.Notification{Channel: n.Channel, Payload: n.Payload})
	}
}
