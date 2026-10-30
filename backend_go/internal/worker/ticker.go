// Package worker holds small background loops started from main.
package worker

import (
	"context"
	"fmt"
	"time"
)

// ClampPKInterval keeps the PK ticker between 2 and 5 seconds (0 = default 3s).
func ClampPKInterval(d time.Duration) time.Duration {
	switch {
	case d <= 0:
		return 3 * time.Second
	case d < 2*time.Second:
		return 2 * time.Second
	case d > 5*time.Second:
		return 5 * time.Second
	}
	return d
}

// RunEvery calls fn every interval until ctx ends. A failing or panicking fn never stops the loop,
// and ticks never overlap (a slow fn just delays the next tick).
func RunEvery(ctx context.Context, interval time.Duration, name string, fn func(context.Context) error, logf func(string, ...any)) {
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if err := safe(ctx, fn); err != nil && ctx.Err() == nil {
				logf("worker %s: %v", name, err)
			}
		}
	}
}

func safe(ctx context.Context, fn func(context.Context) error) (err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("panic: %v", r)
		}
	}()
	return fn(ctx)
}

// PKFinisher closes every PK battle whose time is up and returns how many it closed.
type PKFinisher func(ctx context.Context) (int, error)

// RunPKTicker finishes expired PK battles every 2-5 seconds. pk_finish_due() is idempotent and
// locks each battle row, so running it on several API instances at once is safe.
func RunPKTicker(ctx context.Context, interval time.Duration, finish PKFinisher, logf func(string, ...any)) {
	runPK(ctx, ClampPKInterval(interval), finish, logf)
}

func runPK(ctx context.Context, interval time.Duration, finish PKFinisher, logf func(string, ...any)) {
	RunEvery(ctx, interval, "pk_finish_due", func(ctx context.Context) error {
		n, err := finish(ctx)
		if err != nil {
			return err
		}
		if n > 0 {
			logf("worker pk_finish_due: closed %d battle(s)", n)
		}
		return nil
	}, logf)
}
