package worker

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"
)

func TestClampPKInterval(t *testing.T) {
	cases := map[time.Duration]time.Duration{
		0: 3 * time.Second, -1: 3 * time.Second, 500 * time.Millisecond: 2 * time.Second,
		2 * time.Second: 2 * time.Second, 4 * time.Second: 4 * time.Second, 5 * time.Second: 5 * time.Second,
		time.Minute: 5 * time.Second,
	}
	for in, want := range cases {
		if got := ClampPKInterval(in); got != want {
			t.Errorf("Clamp(%v)=%v want %v", in, got, want)
		}
	}
}

func TestRunEverySurvivesErrorsAndPanics(t *testing.T) {
	var calls atomic.Int32
	var logs atomic.Int32
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		RunEvery(ctx, 5*time.Millisecond, "t", func(context.Context) error {
			switch calls.Add(1) {
			case 1:
				return errors.New("boom")
			case 2:
				panic("kaboom")
			}
			return nil
		}, func(string, ...any) { logs.Add(1) })
		close(done)
	}()
	deadline := time.After(2 * time.Second)
	for calls.Load() < 5 {
		select {
		case <-deadline:
			t.Fatalf("loop died after %d calls", calls.Load())
		case <-time.After(5 * time.Millisecond):
		}
	}
	cancel()
	<-done
	if logs.Load() != 2 {
		t.Fatalf("logged %d failures, want 2 (error + panic)", logs.Load())
	}
}

func TestTicksNeverOverlap(t *testing.T) {
	var running, maxRunning, calls atomic.Int32
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()
	RunEvery(ctx, 5*time.Millisecond, "slow", func(context.Context) error {
		n := running.Add(1)
		if n > maxRunning.Load() {
			maxRunning.Store(n)
		}
		time.Sleep(20 * time.Millisecond)
		running.Add(-1)
		calls.Add(1)
		return nil
	}, func(string, ...any) {})
	if maxRunning.Load() != 1 || calls.Load() == 0 {
		t.Fatalf("overlap=%d calls=%d", maxRunning.Load(), calls.Load())
	}
}

func TestPKTickerCallsFinisher(t *testing.T) {
	var calls atomic.Int32
	var logged atomic.Int32
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Millisecond)
	defer cancel()
	runPK(ctx, 10*time.Millisecond, func(context.Context) (int, error) {
		if calls.Add(1) == 3 {
			return 2, nil // closed two battles -> logged
		}
		return 0, nil
	}, func(string, ...any) { logged.Add(1) })
	if calls.Load() < 5 {
		t.Fatalf("finisher called only %d times", calls.Load())
	}
	if logged.Load() != 1 {
		t.Fatalf("logged %d times, want 1 (only when something was closed)", logged.Load())
	}
}
