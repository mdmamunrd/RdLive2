// Package coinx holds the pure (dependency-free) rules of the coin distribution
// system: input validation, idempotency-key namespacing and the mapping from
// PostgreSQL exception messages to HTTP responses. Keeping it free of pgx/chi
// lets it be unit-tested anywhere.
package coinx

import (
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

const (
	DefaultDailyLimit           int64 = 5_000_000
	DefaultPerTransferMax       int64 = 1_000_000
	MaxAmount                   int64 = 1_000_000_000 // sanity ceiling for any single request
	maxNoteRunes                      = 200
	maxPaymentRefRunes                = 64
	maxReasonRunes                    = 200
	SellerRole                        = "coin_seller"
	SuperAdminRole                    = "super_admin"
	HostRole                          = "host"
	StatusActive                      = "active"
	StatusSuspended                   = "suspended"
	maxIdempotencyKeyLen              = 64
	minIdempotencyKeyLen              = 8
	retryableDeadlockSQLState         = "40P01"
	retryableSerializationSQLSt       = "40001"
)

var (
	idemRe       = regexp.MustCompile(`^[A-Za-z0-9_\-:.]{8,64}$`)
	sellerCodeRe = regexp.MustCompile(`^[A-Z0-9][A-Z0-9_-]{2,19}$`)
	methods      = map[string]bool{"bkash": true, "nagad": true, "rocket": true, "bank": true, "cash": true}
)

// ValidIdemKey reports whether a client-supplied Idempotency-Key is acceptable.
func ValidIdemKey(k string) bool {
	return len(k) >= minIdempotencyKeyLen && len(k) <= maxIdempotencyKeyLen && idemRe.MatchString(k)
}

// NamespaceKey binds a client key to the acting user so one account can never
// collide with (or probe) another account's keys.
func NamespaceKey(actor int64, key string) string {
	return "a" + strconv.FormatInt(actor, 10) + ":" + key
}

func ValidSellerCode(c string) bool    { return sellerCodeRe.MatchString(c) }
func ValidPaymentMethod(m string) bool { return methods[m] }

// ValidAmount: 1 <= amount <= min(max, MaxAmount).
func ValidAmount(amount, max int64) bool {
	if max <= 0 || max > MaxAmount {
		max = MaxAmount
	}
	return amount >= 1 && amount <= max
}

// ValidPublicID: user-facing IDs are 8 digits (10,000,000 .. 99,999,999).
func ValidPublicID(id int64) bool { return id >= 10_000_000 && id <= 99_999_999 }

// CleanText trims s, rejects control characters and enforces a rune limit.
func CleanText(s string, maxRunes int) (string, bool) {
	s = strings.TrimSpace(s)
	if utf8.RuneCountInString(s) > maxRunes || !utf8.ValidString(s) {
		return "", false
	}
	for _, r := range s {
		if unicode.IsControl(r) {
			return "", false
		}
	}
	return s, true
}

// CleanMultiline is for chat messages: like CleanText but newlines and tabs are allowed.
func CleanMultiline(s string, maxRunes int) (string, bool) {
	s = strings.TrimSpace(s)
	if utf8.RuneCountInString(s) > maxRunes || !utf8.ValidString(s) {
		return "", false
	}
	for _, r := range s {
		if unicode.IsControl(r) && r != '\n' && r != '\t' && r != '\r' {
			return "", false
		}
	}
	return s, true
}

func CleanNote(s string) (string, bool)       { return CleanText(s, maxNoteRunes) }
func CleanPaymentRef(s string) (string, bool) { return CleanText(s, maxPaymentRefRunes) }
func CleanReason(s string) (string, bool)     { return CleanText(s, maxReasonRunes) }

// Retryable reports a deadlock / serialization failure: safe to run once more
// because the whole SQL function rolled back.
func Retryable(sqlState string) bool {
	return sqlState == retryableDeadlockSQLState || sqlState == retryableSerializationSQLSt
}

type rule struct {
	prefix  string
	status  int
	code    string
	message string
}

// Order matters: the first matching prefix wins.
var rules = []rule{
	{"forbidden:", http.StatusForbidden, "forbidden", "you are not allowed to do this"},
	{"idempotency key required", http.StatusBadRequest, "idempotency_key_required", "send an Idempotency-Key header"},
	{"idempotency key reused", http.StatusConflict, "idempotency_conflict", "this Idempotency-Key was already used for a different request"},
	{"amount out of range", http.StatusBadRequest, "amount_out_of_range", "amount is outside the allowed range"},
	{"reason required", http.StatusBadRequest, "reason_required", "a reason is required"},
	{"invalid quantity", http.StatusBadRequest, "bad_request", "invalid quantity"},
	{"cannot transfer to yourself", http.StatusBadRequest, "self_transfer", "you cannot transfer coins to yourself"},
	{"cannot gift yourself", http.StatusBadRequest, "self_gift", "you cannot gift yourself"},
	{"recipient not found", http.StatusNotFound, "not_found", "recipient not found"},
	{"seller not found", http.StatusNotFound, "not_found", "seller not found"},
	{"user not found", http.StatusNotFound, "not_found", "user not found"},
	{"recipient not allowed", http.StatusUnprocessableEntity, "recipient_not_allowed", "this account cannot receive coins from a seller"},
	{"user not allowed", http.StatusUnprocessableEntity, "user_not_allowed", "this account cannot be made a coin seller"},
	{"seller not active", http.StatusConflict, "seller_not_active", "seller is not active"},
	{"daily limit exceeded", http.StatusTooManyRequests, "daily_limit_exceeded", "daily selling limit reached"},
	{"daily mint cap exceeded", http.StatusTooManyRequests, "mint_cap_exceeded", "daily mint cap reached"},
	{"insufficient", http.StatusPaymentRequired, "insufficient_balance", "not enough coins"},
	{"duplicate payment reference", http.StatusConflict, "duplicate_payment_ref", "this payment reference was already used"},
	{"seller code already used", http.StatusConflict, "seller_code_taken", "seller code already used"},
	{"receiver not in room", http.StatusForbidden, "receiver_not_in_room", "the receiver is not in this room"},
	{"not in room", http.StatusForbidden, "not_in_room", "you are not in this room"},
	{"room not live", http.StatusGone, "room_not_live", "room is not live"},
	{"gift not available", http.StatusNotFound, "gift_not_found", "gift not available"},
	{"level too low", http.StatusForbidden, "level_too_low", "your level is too low for this gift"},

	// ---- rooms / seats / moderation / PK (002) ----
	{"room not found", http.StatusNotFound, "room_not_found", "room not found"},
	{"target not in room", http.StatusNotFound, "target_not_in_room", "that user is not in the room"},
	{"target not seated", http.StatusConflict, "target_not_seated", "that user is not on a seat"},
	{"request not found", http.StatusNotFound, "request_not_found", "seat request not found"},
	{"seat not found", http.StatusNotFound, "seat_not_found", "seat not found"},
	{"ban not found", http.StatusNotFound, "ban_not_found", "no active ban for this user"},
	{"battle not found", http.StatusNotFound, "battle_not_found", "PK battle not found"},
	{"seat taken", http.StatusConflict, "seat_taken", "that seat is taken"},
	{"seat locked", http.StatusConflict, "seat_locked", "that seat is locked"},
	{"seat not empty", http.StatusConflict, "seat_not_empty", "only an empty seat can be locked"},
	{"seat not locked", http.StatusConflict, "seat_not_locked", "that seat is not locked"},
	{"seat cannot be locked", http.StatusConflict, "seat_not_lockable", "the host seat cannot be locked"},
	{"host seat cannot be left", http.StatusConflict, "host_seat", "the host seat cannot be left"},
	{"host must end the room", http.StatusConflict, "host_must_end", "the host must end the room"},
	{"already seated", http.StatusConflict, "already_seated", "you already have a seat"},
	{"not seated", http.StatusConflict, "not_seated", "you are not on a seat"},
	{"no free seat", http.StatusConflict, "no_free_seat", "no free seat"},
	{"request already pending", http.StatusConflict, "request_pending", "you already have a pending request"},
	{"room already live", http.StatusConflict, "room_already_live", "you already have a live room"},
	{"host already in a PK", http.StatusConflict, "host_in_pk", "a host is already in a PK battle"},
	{"pk not ready", http.StatusConflict, "pk_not_ready", "this PK battle was already started"},
	{"pk not finished", http.StatusConflict, "pk_not_finished", "this PK battle is not finished"},
	{"banned from room", http.StatusForbidden, "banned", "you are banned from this host's rooms"},
	{"muted by host", http.StatusForbidden, "muted", "you were muted by the host"},
	{"invalid role", http.StatusBadRequest, "bad_request", "invalid role"},
	{"invalid opponent", http.StatusBadRequest, "bad_request", "invalid opponent"},

	// ---- follows / chat / media (004) ----
	{"blocked", http.StatusForbidden, "blocked", "you cannot interact with this user"},
	{"rate limited", http.StatusTooManyRequests, "rate_limited", "slow down a little"},
	{"conversation not found", http.StatusNotFound, "conversation_not_found", "conversation not found"},
	{"message too long", http.StatusBadRequest, "message_too_long", "message is too long"},
	{"empty message", http.StatusBadRequest, "empty_message", "message is empty"},
	{"media not allowed on text", http.StatusBadRequest, "bad_request", "a text message cannot carry media"},
	{"media not found", http.StatusNotFound, "media_not_found", "image not found"},
	{"media not ready", http.StatusConflict, "media_not_ready", "the image upload is not finished"},
	{"media already used", http.StatusConflict, "media_used", "this image was already sent"},
	{"media too large", http.StatusRequestEntityTooLarge, "media_too_large", "image is too large"},
	{"unsupported media type", http.StatusUnsupportedMediaType, "unsupported_media", "unsupported image type"},
	{"recipient not available", http.StatusConflict, "recipient_unavailable", "this user cannot receive messages"},
	{"cannot message yourself", http.StatusBadRequest, "self_message", "you cannot message yourself"},
	{"cannot follow yourself", http.StatusBadRequest, "self_follow", "you cannot follow yourself"},
	{"cannot block yourself", http.StatusBadRequest, "self_block", "you cannot block yourself"},
}

// MapError converts a PostgreSQL exception (message + SQLSTATE) into an HTTP
// answer. ok=false means "unknown": the caller should log it and return a
// generic 500 — internals are never leaked to clients.
func MapError(message, sqlState string) (status int, code, public string, ok bool) {
	for _, r := range rules {
		if strings.HasPrefix(message, r.prefix) {
			return r.status, r.code, r.message, true
		}
	}
	switch sqlState {
	case "23514":
		return http.StatusBadRequest, "bad_request", "invalid value", true
	case "23503":
		return http.StatusNotFound, "not_found", "referenced record not found", true
	}
	return 0, "", "", false
}
