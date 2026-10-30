//go:build pgintegration

package realtime

// End-to-end test against a REAL PostgreSQL: SQL function -> pg_notify -> listener -> dispatcher -> hub -> client queue.
// It needs the `psql` binary and a database that has schema.sql + 002..005 loaded plus the seed
// in database_sql/dev_seed.sql (or any database that contains users "c1","c3" and a live room of host "c4"):
//
//	RD_PSQL_ARGS="-h /tmp/pgt -p 5544 -U postgres -d t" go test -tags pgintegration -race -run PG ./internal/realtime
//
// The production listener (internal/pgnotify) uses pgx; this test drives the same realtime.Source
// interface through psql so it runs without any third-party module.

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

type psqlSource struct {
	args    []string
	started func(*exec.Cmd)
}

func (s *psqlSource) Listen(ctx context.Context, channels []string, onReady func(), handle func(Notification)) error {
	cmd := exec.CommandContext(ctx, "psql", append(append([]string{}, s.args...), "-X", "-q", "-t", "-A")...)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	cmd.Stderr = cmd.Stdout
	if err := cmd.Start(); err != nil {
		return err
	}
	if s.started != nil {
		s.started(cmd)
	}
	for _, ch := range channels {
		fmt.Fprintf(stdin, "listen %s;\n", ch)
	}
	fmt.Fprint(stdin, "select 'LISTENING';\n")
	go func() { // psql only prints notifications between commands: poke it
		t := time.NewTicker(30 * time.Millisecond)
		defer t.Stop()
		for range t.C {
			if _, err := fmt.Fprint(stdin, "select 1;\n"); err != nil {
				return
			}
		}
	}()
	sc := bufio.NewScanner(stdout)
	sc.Buffer(make([]byte, 0, 64<<10), 1<<20)
	for sc.Scan() {
		line := sc.Text()
		switch {
		case line == "LISTENING":
			onReady()
		case strings.HasPrefix(line, `Asynchronous notification "`):
			rest := line[len(`Asynchronous notification "`):]
			ch, after, _ := strings.Cut(rest, `"`)
			after = strings.TrimPrefix(after, ` with payload "`)
			if i := strings.LastIndex(after, `" received from server process`); i >= 0 {
				handle(Notification{Channel: ch, Payload: after[:i]})
			}
		}
	}
	_ = cmd.Wait()
	return fmt.Errorf("psql exited")
}

func psqlArgs(t *testing.T) []string {
	a := os.Getenv("RD_PSQL_ARGS")
	if a == "" {
		t.Skip("set RD_PSQL_ARGS to run the PostgreSQL integration test")
	}
	return strings.Fields(a)
}

func sql(t *testing.T, args []string, q string) string {
	t.Helper()
	out, err := exec.Command("psql", append(append([]string{}, args...), "-X", "-q", "-t", "-A", "-c", q)...).CombinedOutput()
	if err != nil {
		t.Fatalf("sql %q: %v\n%s", q, err, out)
	}
	return strings.TrimSpace(string(out))
}

func sqlInt(t *testing.T, args []string, q string) int64 {
	t.Helper()
	n, err := strconv.ParseInt(strings.Fields(sql(t, args, q))[0], 10, 64)
	if err != nil {
		t.Fatalf("not a number from %q", q)
	}
	return n
}

// waitFor collects messages from c until match returns true or the timeout hits.
func waitFor(t *testing.T, c *Client, what string, match func(map[string]any) bool) map[string]any {
	t.Helper()
	deadline := time.After(10 * time.Second)
	for {
		select {
		case b := <-c.Send():
			var m map[string]any
			_ = json.Unmarshal(b, &m)
			if match(m) {
				return m
			}
		case <-deadline:
			t.Fatalf("timed out waiting for %s", what)
		}
	}
}

func TestPGEndToEnd(t *testing.T) {
	args := psqlArgs(t)
	oldBase := backoffBase
	backoffBase = 100 * time.Millisecond
	defer func() { backoffBase = oldBase }()

	u1 := sqlInt(t, args, `select id from users where display_name='c1'`)
	u3 := sqlInt(t, args, `select id from users where display_name='c3'`)
	room := sqlInt(t, args, `select id from live_rooms where status='live' order by id limit 1`)
	host := sqlInt(t, args, fmt.Sprintf(`select host_id from live_rooms where id=%d`, room))

	hub := NewHub(5)
	d := NewDispatcher(hub, func(ctx context.Context, id int64) (json.RawMessage, error) {
		return json.RawMessage(fmt.Sprintf(`{"id":%d}`, id)), nil
	})
	d.Logf = t.Logf
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go d.RunChat(ctx)

	var mu sync.Mutex
	var cmd *exec.Cmd
	src := &psqlSource{args: args, started: func(c *exec.Cmd) { mu.Lock(); cmd = c; mu.Unlock() }}
	ready := make(chan struct{}, 4)
	go RunListener(ctx, src, []string{ChannelRoom, ChannelChat}, d.Handle, d.Resync, t.Logf)
	go func() { // RunListener has no ready hook of its own: wait until psql is up
		time.Sleep(700 * time.Millisecond)
		ready <- struct{}{}
	}()
	<-ready

	watcher := NewClient(u3, 128, nil) // a room viewer who is also a chat user
	other := NewClient(u1, 128, nil)
	for _, c := range []*Client{watcher, other} {
		if err := hub.Add(c); err != nil {
			t.Fatal(err)
		}
	}
	hub.Subscribe(watcher, room)

	// 1. a room event produced by a SQL function reaches the subscribed client
	sql(t, args, fmt.Sprintf(`select room_join(%d,%d)`, room, u3))
	m := waitFor(t, watcher, "members_changed", func(m map[string]any) bool { return m["event"] == "members_changed" })
	if m["type"] != "room_event" || int64(m["room_id"].(float64)) != room {
		t.Fatalf("bad envelope: %v", m)
	}

	// 2. seat request flow -> seats/requests events
	sql(t, args, fmt.Sprintf(`select seat_request_create(%d,%d,null)`, room, u3))
	waitFor(t, watcher, "requests_changed", func(m map[string]any) bool { return m["event"] == "requests_changed" })

	// 3. a client that is NOT subscribed gets no room events
	select {
	case b := <-other.Send():
		t.Fatalf("unsubscribed client received %s", b)
	default:
	}

	// 4. chat: both participants get the message pushed (loaded by the dispatcher), then the read receipt
	conv := sqlInt(t, args, fmt.Sprintf(`select chat_open(%d,%d)`, u1, u3))
	msg := sqlInt(t, args, fmt.Sprintf(`select chat_send(%d,%d,'text','e2e hello',null,'e2e-%d')`, u1, conv, time.Now().UnixNano()))
	for name, c := range map[string]*Client{"sender": other, "recipient": watcher} {
		got := waitFor(t, c, name+" chat_message", func(m map[string]any) bool { return m["type"] == "chat_message" })
		if int64(got["message"].(map[string]any)["id"].(float64)) != msg {
			t.Fatalf("%s got wrong message: %v", name, got)
		}
	}
	sql(t, args, fmt.Sprintf(`select chat_mark_read(%d,%d)`, u3, conv))
	rd := waitFor(t, other, "chat_read", func(m map[string]any) bool { return m["type"] == "chat_read" })
	if int64(rd["up_to_message_id"].(float64)) != msg || int64(rd["reader_id"].(float64)) != u3 {
		t.Fatalf("bad read receipt: %v", rd)
	}

	// 5. kicked users stop receiving that room
	if host != u3 {
		sql(t, args, fmt.Sprintf(`select room_kick_user(%d,%d,%d)`, room, host, u3))
		waitFor(t, watcher, "kicked", func(m map[string]any) bool { return m["event"] == "kicked" })
		time.Sleep(200 * time.Millisecond)
		sql(t, args, fmt.Sprintf(`select room_join(%d,%d)`, room, u3)) // rejoin: a new event the kicked socket must NOT get
		time.Sleep(500 * time.Millisecond)
		for {
			select {
			case b := <-watcher.Send():
				var x map[string]any
				_ = json.Unmarshal(b, &x)
				if x["type"] == "room_event" {
					t.Fatalf("kicked socket still receives room events: %s", b)
				}
			default:
				goto reconnect
			}
		}
	}

reconnect:
	// 6. the listener connection dies: it reconnects by itself and tells everyone to resync
	hub.Subscribe(other, room)
	mu.Lock()
	_ = cmd.Process.Kill()
	mu.Unlock()
	waitFor(t, other, "resync after reconnect", func(m map[string]any) bool { return m["type"] == "resync" })
	sql(t, args, fmt.Sprintf(`select room_join(%d,%d)`, room, u1))
	waitFor(t, other, "events flow again after reconnect", func(m map[string]any) bool { return m["event"] == "members_changed" })
}
