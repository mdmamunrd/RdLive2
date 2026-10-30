package ws

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// ---- tiny test client ------------------------------------------------------

type tc struct {
	t  *testing.T
	c  net.Conn
	br *bufio.Reader
}

func dial(t *testing.T, srv *httptest.Server, hdr map[string]string) (*tc, string) {
	t.Helper()
	c, err := net.Dial("tcp", strings.TrimPrefix(srv.URL, "http://"))
	if err != nil {
		t.Fatal(err)
	}
	key := base64.StdEncoding.EncodeToString([]byte("0123456789abcdef"))
	req := "GET /ws HTTP/1.1\r\nHost: " + strings.TrimPrefix(srv.URL, "http://") + "\r\n" +
		"Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: " + key + "\r\n"
	for k, v := range hdr {
		req += k + ": " + v + "\r\n"
	}
	req += "\r\n"
	_, _ = c.Write([]byte(req))
	br := bufio.NewReader(c)
	line, err := br.ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	for { // swallow headers
		l, err := br.ReadString('\n')
		if err != nil || l == "\r\n" {
			break
		}
	}
	t.Cleanup(func() { _ = c.Close() })
	return &tc{t: t, c: c, br: br}, line
}

func (c *tc) send(fin bool, op int, payload []byte, masked bool) {
	b := []byte{byte(op)}
	if fin {
		b[0] |= 0x80
	}
	m := byte(0)
	if masked {
		m = 0x80
	}
	switch n := len(payload); {
	case n <= 125:
		b = append(b, m|byte(n))
	case n <= 0xFFFF:
		b = append(b, m|126, byte(n>>8), byte(n))
	default:
		b = append(b, m|127)
		var x [8]byte
		binary.BigEndian.PutUint64(x[:], uint64(n))
		b = append(b, x[:]...)
	}
	if masked {
		mask := []byte{1, 2, 3, 4}
		b = append(b, mask...)
		for i, p := range payload {
			b = append(b, p^mask[i&3])
		}
	} else {
		b = append(b, payload...)
	}
	if _, err := c.c.Write(b); err != nil {
		c.t.Fatal(err)
	}
}

func (c *tc) recv() (op int, payload []byte) {
	c.t.Helper()
	_ = c.c.SetReadDeadline(time.Now().Add(3 * time.Second))
	var h [2]byte
	if _, err := io.ReadFull(c.br, h[:]); err != nil {
		c.t.Fatalf("read header: %v", err)
	}
	op = int(h[0] & 0x0F)
	n := int(h[1] & 0x7F)
	switch n {
	case 126:
		var b [2]byte
		_, _ = io.ReadFull(c.br, b[:])
		n = int(binary.BigEndian.Uint16(b[:]))
	case 127:
		var b [8]byte
		_, _ = io.ReadFull(c.br, b[:])
		n = int(binary.BigEndian.Uint64(b[:]))
	}
	payload = make([]byte, n)
	_, _ = io.ReadFull(c.br, payload)
	return
}

func closeCode(p []byte) int { return int(binary.BigEndian.Uint16(p)) }

// echoServer upgrades and echoes every message back; errors are reported on errc.
func echoServer(t *testing.T, opts Options) (*httptest.Server, chan error) {
	errc := make(chan error, 4)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := Upgrade(w, r, opts)
		if err != nil {
			return
		}
		for {
			op, data, err := c.ReadMessage()
			if err != nil {
				errc <- err
				return
			}
			if op == OpText {
				_ = c.WriteText(data)
			}
		}
	}))
	t.Cleanup(srv.Close)
	return srv, errc
}

// ---- tests -----------------------------------------------------------------

func TestAcceptKeyRFCExample(t *testing.T) {
	// RFC 6455 section 1.3
	if got := AcceptKey("dGhlIHNhbXBsZSBub25jZQ=="); got != "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" {
		t.Fatalf("accept key %q", got)
	}
}

func TestHandshakeAndEcho(t *testing.T) {
	srv, _ := echoServer(t, Options{})
	c, status := dial(t, srv, nil)
	if !strings.Contains(status, "101") {
		t.Fatalf("status %q", status)
	}
	c.send(true, OpText, []byte("héllo বাংলা"), true)
	op, p := c.recv()
	if op != OpText || string(p) != "héllo বাংলা" {
		t.Fatalf("echo got op=%d %q", op, p)
	}
	big := bytes.Repeat([]byte("a"), 40000) // 64-bit/16-bit length paths
	c.send(true, OpText, big, true)
	if op, p = c.recv(); op != OpText || !bytes.Equal(p, big) {
		t.Fatal("large echo mismatch")
	}
}

func TestFragmentedMessageWithInterleavedPing(t *testing.T) {
	srv, _ := echoServer(t, Options{})
	c, _ := dial(t, srv, nil)
	c.send(false, OpText, []byte("hel"), true)
	c.send(true, OpPing, []byte("p"), true) // control frames may interleave
	c.send(true, OpContinuation, []byte("lo"), true)
	op, p := c.recv()
	if op != OpPong || string(p) != "p" {
		t.Fatalf("want pong, got op=%d %q", op, p)
	}
	if op, p = c.recv(); op != OpText || string(p) != "hello" {
		t.Fatalf("want reassembled hello, got op=%d %q", op, p)
	}
}

func TestProtocolViolationsClose(t *testing.T) {
	cases := []struct {
		name string
		do   func(c *tc)
		code int
	}{
		{"unmasked client frame", func(c *tc) { c.send(true, OpText, []byte("x"), false) }, CloseProtocolError},
		{"invalid utf8", func(c *tc) { c.send(true, OpText, []byte{0xff, 0xfe}, true) }, CloseInvalidPayload},
		{"too big", func(c *tc) { c.send(true, OpText, bytes.Repeat([]byte("a"), 200), true) }, CloseTooBig},
		{"orphan continuation", func(c *tc) { c.send(true, OpContinuation, []byte("x"), true) }, CloseProtocolError},
		{"fragmented control frame", func(c *tc) { c.send(false, OpPing, nil, true) }, CloseProtocolError},
		{"unknown opcode", func(c *tc) { c.send(true, 0x3, nil, true) }, CloseProtocolError},
	}
	for _, tcse := range cases {
		t.Run(tcse.name, func(t *testing.T) {
			srv, errc := echoServer(t, Options{MaxMessage: 100})
			c, _ := dial(t, srv, nil)
			tcse.do(c)
			op, p := c.recv()
			if op != OpClose || closeCode(p) != tcse.code {
				t.Fatalf("want close %d, got op=%d payload=%v", tcse.code, op, p)
			}
			select {
			case <-errc:
			case <-time.After(2 * time.Second):
				t.Fatal("server loop did not stop")
			}
		})
	}
}

func TestClientCloseHandshake(t *testing.T) {
	srv, errc := echoServer(t, Options{})
	c, _ := dial(t, srv, nil)
	c.send(true, OpClose, []byte{0x03, 0xE8}, true)
	op, p := c.recv()
	if op != OpClose || closeCode(p) != 1000 {
		t.Fatalf("op=%d p=%v", op, p)
	}
	if err := <-errc; err != ErrClosed {
		t.Fatalf("server err %v", err)
	}
}

func TestBadHandshakes(t *testing.T) {
	srv, _ := echoServer(t, Options{})
	get := func(h map[string]string) int {
		req, _ := http.NewRequest("GET", srv.URL, nil)
		for k, v := range h {
			req.Header.Set(k, v)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		return resp.StatusCode
	}
	good := map[string]string{
		"Connection": "Upgrade", "Upgrade": "websocket", "Sec-WebSocket-Version": "13",
		"Sec-WebSocket-Key": base64.StdEncoding.EncodeToString([]byte("0123456789abcdef")),
	}
	with := func(k, v string) map[string]string {
		m := map[string]string{}
		for a, b := range good {
			m[a] = b
		}
		m[k] = v
		return m
	}
	if c := get(nil); c != http.StatusUpgradeRequired {
		t.Errorf("plain GET -> %d", c)
	}
	if c := get(with("Sec-WebSocket-Version", "8")); c != http.StatusUpgradeRequired {
		t.Errorf("bad version -> %d", c)
	}
	if c := get(with("Sec-WebSocket-Key", "short")); c != http.StatusBadRequest {
		t.Errorf("bad key -> %d", c)
	}
	if c := get(with("Origin", "https://evil.example")); c != http.StatusForbidden {
		t.Errorf("foreign origin -> %d (want 403)", c)
	}
}

func TestOriginAllowList(t *testing.T) {
	srv, _ := echoServer(t, Options{CheckOrigin: func(r *http.Request) bool { return r.Header.Get("Origin") == "https://admin.example.com" }})
	if _, line := dial(t, srv, map[string]string{"Origin": "https://admin.example.com"}); !strings.Contains(line, "101") {
		t.Fatalf("allowed origin rejected: %q", line)
	}
	if _, line := dial(t, srv, map[string]string{"Origin": "https://evil.example"}); !strings.Contains(line, "403") {
		t.Fatalf("evil origin accepted: %q", line)
	}
	if _, line := dial(t, srv, nil); !strings.Contains(line, "101") {
		t.Fatalf("no-origin (mobile) rejected: %q", line)
	}
}

func TestConcurrentWritersAreSafe(t *testing.T) {
	var server *Conn
	ready := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := Upgrade(w, r, Options{})
		if err != nil {
			return
		}
		server = c
		close(ready)
		_, _, _ = c.ReadMessage()
	}))
	defer srv.Close()
	c, _ := dial(t, srv, nil)
	<-ready
	var wg sync.WaitGroup
	const writers, per = 8, 50
	for i := 0; i < writers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < per; j++ {
				_ = server.WriteText([]byte(`{"type":"x","n":1234567890}`))
			}
		}()
	}
	for i := 0; i < writers*per; i++ {
		op, p := c.recv()
		if op != OpText || string(p) != `{"type":"x","n":1234567890}` {
			t.Fatalf("interleaved/corrupt frame #%d: op=%d %q", i, op, p)
		}
	}
	wg.Wait()
}

func TestReadTimeout(t *testing.T) {
	srv, errc := echoServer(t, Options{ReadTimeout: 100 * time.Millisecond})
	_, _ = dial(t, srv, nil)
	select {
	case err := <-errc:
		if err == nil {
			t.Fatal("want timeout error")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("idle connection was not dropped")
	}
}

func TestInvalidCloseFramesAreProtocolErrors(t *testing.T) {
	cases := []struct {
		name    string
		payload []byte
		want    int
	}{
		{"1-byte payload", []byte{0x03}, CloseProtocolError},
		{"code 1005 must not be sent", []byte{0x03, 0xED}, CloseProtocolError},
		{"code 1006 must not be sent", []byte{0x03, 0xEE}, CloseProtocolError},
		{"code 999", []byte{0x03, 0xE7}, CloseProtocolError},
		{"code 2000 is reserved", []byte{0x07, 0xD0}, CloseProtocolError},
		{"reason is not utf-8", []byte{0x03, 0xE8, 0xff, 0xfe}, CloseInvalidPayload},
		{"valid code + reason echoes the code", append([]byte{0x03, 0xE9}, "bye"...), 1001},
		{"application code 4000", []byte{0x0F, 0xA0}, 4000},
	}
	for _, tcse := range cases {
		t.Run(tcse.name, func(t *testing.T) {
			srv, errc := echoServer(t, Options{})
			c, _ := dial(t, srv, nil)
			c.send(true, OpClose, tcse.payload, true)
			op, p := c.recv()
			if op != OpClose || closeCode(p) != tcse.want {
				t.Fatalf("want close %d, got op=%d payload=%v", tcse.want, op, p)
			}
			<-errc
		})
	}
}
