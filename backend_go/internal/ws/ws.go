// Package ws is a small, dependency-free WebSocket (RFC 6455) SERVER.
//
// It exists because the build sandbox could not download third-party modules.
// The surface is deliberately tiny (Upgrade / ReadMessage / WriteText / Close), so
// swapping it for gorilla/websocket or coder/websocket later is a one-file change.
//
// Supported: text + binary messages, fragmentation, ping/pong, close handshake,
// message size limit, UTF-8 validation, mandatory client masking, origin check.
// Not supported: extensions (permessage-deflate), subprotocol negotiation.
package ws

import (
	"bufio"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

const (
	OpContinuation = 0x0
	OpText         = 0x1
	OpBinary       = 0x2
	OpClose        = 0x8
	OpPing         = 0x9
	OpPong         = 0xA
)

// Close codes (RFC 6455 section 7.4.1).
const (
	CloseNormal          = 1000
	CloseGoingAway       = 1001
	CloseProtocolError   = 1002
	CloseUnsupported     = 1003
	CloseInvalidPayload  = 1007
	ClosePolicyViolation = 1008
	CloseTooBig          = 1009
	CloseInternal        = 1011
)

var (
	ErrClosed = errors.New("ws: connection closed")
	// ErrProtocol is returned (after the close frame is sent) for malformed input.
	ErrProtocol = errors.New("ws: protocol error")
)

// Options configure Upgrade.
type Options struct {
	MaxMessage   int64         // max bytes of one (reassembled) message; default 64 KiB
	ReadTimeout  time.Duration // extended after every received frame; 0 = none
	WriteTimeout time.Duration // per write; default 10s
	// CheckOrigin decides whether a browser Origin is acceptable. nil = same-host only.
	// Requests WITHOUT an Origin header (mobile apps, curl) are always allowed.
	CheckOrigin func(r *http.Request) bool
}

// Conn is one upgraded connection. ReadMessage must be called from a single goroutine;
// the Write*/Close methods are safe for concurrent use.
type Conn struct {
	c    net.Conn
	br   *bufio.Reader
	opts Options

	wmu    sync.Mutex
	closed bool
}

func headerHasToken(h http.Header, name, token string) bool {
	for _, v := range h.Values(name) {
		for _, part := range strings.Split(v, ",") {
			if strings.EqualFold(strings.TrimSpace(part), token) {
				return true
			}
		}
	}
	return false
}

func sameHost(r *http.Request) bool {
	o := r.Header.Get("Origin")
	i := strings.Index(o, "://")
	return i >= 0 && strings.EqualFold(o[i+3:], r.Host)
}

// AcceptKey computes Sec-WebSocket-Accept for a client key.
func AcceptKey(key string) string {
	h := sha1.Sum([]byte(key + guid))
	return base64.StdEncoding.EncodeToString(h[:])
}

// Upgrade performs the opening handshake. On failure it writes an HTTP error and returns it.
func Upgrade(w http.ResponseWriter, r *http.Request, opts Options) (*Conn, error) {
	if opts.MaxMessage <= 0 {
		opts.MaxMessage = 64 << 10
	}
	if opts.WriteTimeout <= 0 {
		opts.WriteTimeout = 10 * time.Second
	}
	fail := func(code int, msg string) (*Conn, error) {
		http.Error(w, msg, code)
		return nil, errors.New("ws: handshake: " + msg)
	}
	if r.Method != http.MethodGet {
		return fail(http.StatusMethodNotAllowed, "method not allowed")
	}
	if !headerHasToken(r.Header, "Connection", "upgrade") || !headerHasToken(r.Header, "Upgrade", "websocket") {
		return fail(http.StatusUpgradeRequired, "websocket upgrade required")
	}
	if r.Header.Get("Sec-WebSocket-Version") != "13" {
		w.Header().Set("Sec-WebSocket-Version", "13")
		return fail(http.StatusUpgradeRequired, "unsupported websocket version")
	}
	key := r.Header.Get("Sec-WebSocket-Key")
	if raw, err := base64.StdEncoding.DecodeString(key); err != nil || len(raw) != 16 {
		return fail(http.StatusBadRequest, "bad Sec-WebSocket-Key")
	}
	if r.Header.Get("Origin") != "" {
		ok := false
		if opts.CheckOrigin != nil {
			ok = opts.CheckOrigin(r)
		} else {
			ok = sameHost(r)
		}
		if !ok {
			return fail(http.StatusForbidden, "origin not allowed")
		}
	}
	hj, ok := w.(http.Hijacker)
	if !ok {
		return fail(http.StatusInternalServerError, "hijacking not supported")
	}
	nc, rw, err := hj.Hijack()
	if err != nil {
		return nil, err
	}
	// The http.Server's own deadlines stay on a hijacked conn; clear them.
	_ = nc.SetDeadline(time.Time{})

	resp := "HTTP/1.1 101 Switching Protocols\r\n" +
		"Upgrade: websocket\r\nConnection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: " + AcceptKey(key) + "\r\n\r\n"
	_ = nc.SetWriteDeadline(time.Now().Add(opts.WriteTimeout))
	if _, err := rw.WriteString(resp); err != nil {
		_ = nc.Close()
		return nil, err
	}
	if err := rw.Flush(); err != nil {
		_ = nc.Close()
		return nil, err
	}
	_ = nc.SetWriteDeadline(time.Time{})
	return &Conn{c: nc, br: rw.Reader, opts: opts}, nil
}

// SetReadTimeout changes the per-frame read timeout (e.g. short while waiting for auth, longer after).
// Call it from the goroutine that calls ReadMessage.
func (c *Conn) SetReadTimeout(d time.Duration) { c.opts.ReadTimeout = d }

// SetReadDeadline overrides the deadline for the next read (e.g. a short auth window).
func (c *Conn) SetReadDeadline(t time.Time) error { return c.c.SetReadDeadline(t) }

// RemoteAddr returns the peer address.
func (c *Conn) RemoteAddr() net.Addr { return c.c.RemoteAddr() }

// ReadMessage returns the next complete text or binary message. Control frames are
// handled internally. It returns io.EOF / ErrClosed once the connection is closed.
func (c *Conn) ReadMessage() (op int, data []byte, err error) {
	var (
		msgOp int
		buf   []byte
		inMsg bool
	)
	for {
		if c.opts.ReadTimeout > 0 {
			_ = c.c.SetReadDeadline(time.Now().Add(c.opts.ReadTimeout))
		}
		fin, opcode, payload, ferr := c.readFrame()
		if ferr != nil {
			return 0, nil, ferr
		}
		switch opcode {
		case OpPing:
			_ = c.writeFrame(OpPong, payload)
		case OpPong:
		case OpClose:
			code := CloseNormal
			switch {
			case len(payload) == 1: // a close payload is empty or at least a 2-byte code
				return 0, nil, c.fail(CloseProtocolError, "bad close frame")
			case len(payload) >= 2:
				code = int(binary.BigEndian.Uint16(payload))
				if !validCloseCode(code) {
					return 0, nil, c.fail(CloseProtocolError, "bad close code")
				}
				if !utf8.Valid(payload[2:]) {
					return 0, nil, c.fail(CloseInvalidPayload, "invalid utf-8 in close reason")
				}
			}
			_ = c.Close(code, "")
			return 0, nil, ErrClosed
		case OpText, OpBinary:
			if inMsg {
				return 0, nil, c.fail(CloseProtocolError, "new message inside fragmented message")
			}
			msgOp, buf, inMsg = opcode, append([]byte(nil), payload...), !fin
		case OpContinuation:
			if !inMsg {
				return 0, nil, c.fail(CloseProtocolError, "unexpected continuation")
			}
			if int64(len(buf))+int64(len(payload)) > c.opts.MaxMessage {
				return 0, nil, c.fail(CloseTooBig, "message too big")
			}
			buf = append(buf, payload...)
			inMsg = !fin
		default:
			return 0, nil, c.fail(CloseProtocolError, "unknown opcode")
		}
		if (opcode == OpText || opcode == OpBinary || opcode == OpContinuation) && !inMsg {
			if msgOp == OpText && !utf8.Valid(buf) {
				return 0, nil, c.fail(CloseInvalidPayload, "invalid utf-8")
			}
			return msgOp, buf, nil
		}
	}
}

// validCloseCode: RFC 6455 section 7.4 (1004, 1005, 1006 and 1015 must never appear on the wire).
func validCloseCode(code int) bool {
	switch {
	case code >= 1000 && code <= 1014:
		return code != 1004 && code != 1005 && code != 1006
	case code >= 3000 && code <= 4999:
		return true
	}
	return false
}

func (c *Conn) fail(code int, reason string) error {
	_ = c.Close(code, reason)
	return ErrProtocol
}

// readFrame reads one frame and validates it (RFC 6455 section 5).
func (c *Conn) readFrame() (fin bool, opcode int, payload []byte, err error) {
	var h [2]byte
	if _, err = io.ReadFull(c.br, h[:]); err != nil {
		return
	}
	fin = h[0]&0x80 != 0
	opcode = int(h[0] & 0x0F)
	if h[0]&0x70 != 0 { // RSV bits: no extensions negotiated
		err = c.fail(CloseProtocolError, "reserved bits set")
		return
	}
	if h[1]&0x80 == 0 { // client frames MUST be masked
		err = c.fail(CloseProtocolError, "client frame not masked")
		return
	}
	n := int64(h[1] & 0x7F)
	isControl := opcode >= 0x8
	switch n {
	case 126:
		var b [2]byte
		if _, err = io.ReadFull(c.br, b[:]); err != nil {
			return
		}
		n = int64(binary.BigEndian.Uint16(b[:]))
	case 127:
		var b [8]byte
		if _, err = io.ReadFull(c.br, b[:]); err != nil {
			return
		}
		u := binary.BigEndian.Uint64(b[:])
		if u>>63 != 0 {
			err = c.fail(CloseProtocolError, "bad length")
			return
		}
		n = int64(u)
	}
	if isControl && (n > 125 || !fin) {
		err = c.fail(CloseProtocolError, "bad control frame")
		return
	}
	if n > c.opts.MaxMessage {
		err = c.fail(CloseTooBig, "message too big")
		return
	}
	var mask [4]byte
	if _, err = io.ReadFull(c.br, mask[:]); err != nil {
		return
	}
	payload = make([]byte, n)
	if _, err = io.ReadFull(c.br, payload); err != nil {
		return
	}
	for i := range payload {
		payload[i] ^= mask[i&3]
	}
	return
}

func (c *Conn) writeFrame(opcode int, payload []byte) error {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	if c.closed {
		return ErrClosed
	}
	return c.writeFrameLocked(opcode, payload)
}

func (c *Conn) writeFrameLocked(opcode int, payload []byte) error {
	hdr := make([]byte, 0, 10)
	hdr = append(hdr, 0x80|byte(opcode))
	switch n := len(payload); {
	case n <= 125:
		hdr = append(hdr, byte(n))
	case n <= 0xFFFF:
		hdr = append(hdr, 126, byte(n>>8), byte(n))
	default:
		hdr = append(hdr, 127)
		var b [8]byte
		binary.BigEndian.PutUint64(b[:], uint64(n))
		hdr = append(hdr, b[:]...)
	}
	_ = c.c.SetWriteDeadline(time.Now().Add(c.opts.WriteTimeout))
	if _, err := c.c.Write(hdr); err != nil {
		return err
	}
	if len(payload) > 0 {
		if _, err := c.c.Write(payload); err != nil {
			return err
		}
	}
	return nil
}

// WriteText sends one text message (must be valid UTF-8).
func (c *Conn) WriteText(data []byte) error { return c.writeFrame(OpText, data) }

// WritePing sends a ping (payload <= 125 bytes).
func (c *Conn) WritePing() error { return c.writeFrame(OpPing, nil) }

// Close sends a close frame once and closes the socket.
func (c *Conn) Close(code int, reason string) error {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	if c.closed {
		return nil
	}
	c.closed = true
	if len(reason) > 100 {
		reason = reason[:100]
	}
	p := make([]byte, 2, 2+len(reason))
	binary.BigEndian.PutUint16(p, uint16(code))
	p = append(p, reason...)
	_ = c.writeFrameLocked(OpClose, p)
	return c.c.Close()
}
