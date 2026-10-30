package coinx

import (
	"net/http"
	"strings"
	"testing"
)

func TestValidIdemKey(t *testing.T) {
	good := []string{"abcdefgh", "a1b2-c3d4_e5:f6.g7", strings.Repeat("a", 64)}
	bad := []string{"", "short", strings.Repeat("a", 65), "has space 123", "semi;colon1", "ünïcode123"}
	for _, k := range good {
		if !ValidIdemKey(k) {
			t.Errorf("want valid: %q", k)
		}
	}
	for _, k := range bad {
		if ValidIdemKey(k) {
			t.Errorf("want invalid: %q", k)
		}
	}
}

func TestNamespaceKeyIsolatesActors(t *testing.T) {
	if NamespaceKey(1, "same-key-123") == NamespaceKey(2, "same-key-123") {
		t.Fatal("two actors must never share a namespaced key")
	}
	if NamespaceKey(1, "k") != "a1:k" {
		t.Fatalf("unexpected format %q", NamespaceKey(1, "k"))
	}
	// "a1"+"1:x" must not equal "a11"+":x"
	if NamespaceKey(1, "1:x-key-000") == NamespaceKey(11, "x-key-000") {
		t.Fatal("prefix ambiguity")
	}
}

func TestValidAmount(t *testing.T) {
	cases := []struct {
		a, max int64
		want   bool
	}{
		{1, 100, true}, {100, 100, true}, {101, 100, false}, {0, 100, false}, {-5, 100, false},
		{MaxAmount, 0, true}, {MaxAmount + 1, 0, false}, {MaxAmount, MaxAmount * 5, true}, {MaxAmount + 1, MaxAmount * 5, false},
	}
	for _, c := range cases {
		if got := ValidAmount(c.a, c.max); got != c.want {
			t.Errorf("ValidAmount(%d,%d)=%v want %v", c.a, c.max, got, c.want)
		}
	}
}

func TestValidPublicIDAndCodes(t *testing.T) {
	if !ValidPublicID(10_000_000) || !ValidPublicID(99_999_999) || ValidPublicID(9_999_999) || ValidPublicID(100_000_000) || ValidPublicID(0) {
		t.Fatal("public id bounds wrong")
	}
	for _, c := range []string{"S-01", "SELLER_07", "AB1"} {
		if !ValidSellerCode(c) {
			t.Errorf("want valid code %q", c)
		}
	}
	for _, c := range []string{"", "s-01", "-AB", "A", "AB", strings.Repeat("A", 21), "A B C"} {
		if ValidSellerCode(c) {
			t.Errorf("want invalid code %q", c)
		}
	}
	if !ValidPaymentMethod("bkash") || ValidPaymentMethod("paypal") || ValidPaymentMethod("") {
		t.Fatal("payment methods wrong")
	}
}

func TestCleanText(t *testing.T) {
	if s, ok := CleanNote("  hello  "); !ok || s != "hello" {
		t.Fatalf("trim failed: %q %v", s, ok)
	}
	if _, ok := CleanNote("bad\x00byte"); ok {
		t.Fatal("control char accepted")
	}
	if _, ok := CleanNote("line\nbreak"); ok {
		t.Fatal("newline accepted")
	}
	if _, ok := CleanNote(strings.Repeat("ক", 201)); ok {
		t.Fatal("201 runes accepted")
	}
	if _, ok := CleanNote(strings.Repeat("ক", 200)); !ok {
		t.Fatal("200 Bangla runes must be accepted (limit is runes, not bytes)")
	}
	if _, ok := CleanText("\xff\xfe", 10); ok {
		t.Fatal("invalid utf8 accepted")
	}
}

func TestMapError(t *testing.T) {
	cases := []struct {
		msg, state string
		status     int
		code       string
	}{
		{"forbidden: super admin only", "P0001", http.StatusForbidden, "forbidden"},
		{"insufficient coin balance", "P0001", http.StatusPaymentRequired, "insufficient_balance"},
		{"daily limit exceeded", "P0001", http.StatusTooManyRequests, "daily_limit_exceeded"},
		{"daily mint cap exceeded", "P0001", http.StatusTooManyRequests, "mint_cap_exceeded"},
		{"idempotency key reused with different request", "P0001", http.StatusConflict, "idempotency_conflict"},
		{"recipient not allowed", "P0001", http.StatusUnprocessableEntity, "recipient_not_allowed"},
		{"receiver not in room", "P0001", http.StatusForbidden, "receiver_not_in_room"},
		{"not in room", "P0001", http.StatusForbidden, "not_in_room"},
		{"room not live", "P0001", http.StatusGone, "room_not_live"},
		{"duplicate payment reference", "P0001", http.StatusConflict, "duplicate_payment_ref"},
		{"whatever", "23514", http.StatusBadRequest, "bad_request"},
		{"whatever", "23503", http.StatusNotFound, "not_found"},
	}
	for _, c := range cases {
		st, code, _, ok := MapError(c.msg, c.state)
		if !ok || st != c.status || code != c.code {
			t.Errorf("MapError(%q,%q)=(%d,%q,%v) want (%d,%q)", c.msg, c.state, st, code, ok, c.status, c.code)
		}
	}
	// unknown errors must NOT be mapped (caller returns a generic 500)
	if _, _, _, ok := MapError(`relation "wallets" does not exist`, "42P01"); ok {
		t.Fatal("internal errors must not be exposed")
	}
	// "receiver not in room" must win over "not in room" (rule order)
	if _, code, _, _ := MapError("receiver not in room", ""); code != "receiver_not_in_room" {
		t.Fatal("rule order broken")
	}
}

func TestRetryable(t *testing.T) {
	if !Retryable("40P01") || !Retryable("40001") || Retryable("23505") || Retryable("") {
		t.Fatal("retryable states wrong")
	}
}

func TestMapErrorRoomsAndChat(t *testing.T) {
	cases := []struct {
		msg    string
		status int
		code   string
	}{
		{"seat taken", 409, "seat_taken"}, {"seat locked", 409, "seat_locked"}, {"host seat cannot be left", 409, "host_seat"},
		{"banned from room", 403, "banned"}, {"muted by host", 403, "muted"}, {"room not found", 404, "room_not_found"},
		{"target not in room", 404, "target_not_in_room"}, {"host already in a PK", 409, "host_in_pk"},
		{"blocked", 403, "blocked"}, {"rate limited", 429, "rate_limited"}, {"conversation not found", 404, "conversation_not_found"},
		{"media not ready", 409, "media_not_ready"}, {"media too large", 413, "media_too_large"},
		{"unsupported media type", 415, "unsupported_media"}, {"empty message", 400, "empty_message"},
		{"message too long", 400, "message_too_long"}, {"recipient not available", 409, "recipient_unavailable"},
		{"cannot follow yourself", 400, "self_follow"},
	}
	for _, c := range cases {
		st, code, _, ok := MapError(c.msg, "P0001")
		if !ok || st != c.status || code != c.code {
			t.Errorf("MapError(%q)=(%d,%q,%v) want (%d,%q)", c.msg, st, code, ok, c.status, c.code)
		}
	}
	// every rule prefix must be reachable: no earlier, shorter prefix may swallow a later one
	for i, r := range rules {
		for _, e := range rules[:i] {
			if strings.HasPrefix(r.prefix, e.prefix) && r.prefix != e.prefix {
				t.Errorf("rule %q is shadowed by earlier rule %q", r.prefix, e.prefix)
			}
		}
	}
}

func TestCleanMultiline(t *testing.T) {
	if s, ok := CleanMultiline("  hi\nthere 😀 বাংলা\t! ", 50); !ok || s != "hi\nthere 😀 বাংলা\t!" {
		t.Fatalf("got %q %v", s, ok)
	}
	for _, bad := range []string{"a\x00b", "a\x1bb", "\xff", strings.Repeat("x", 51)} {
		if _, ok := CleanMultiline(bad, 50); ok {
			t.Errorf("accepted %q", bad)
		}
	}
}
