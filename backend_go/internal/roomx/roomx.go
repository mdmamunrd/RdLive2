// Package roomx hashes the optional room password. Room passwords are short codes, so the hash
// is keyed with a server-side secret (HMAC-SHA256 + random salt): a stolen database alone cannot
// be brute-forced offline. Online guessing is stopped by rate limiting the join endpoint.
package roomx

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"unicode/utf8"
)

// ValidPassword: 4-16 visible characters.
func ValidPassword(p string) bool {
	n := utf8.RuneCountInString(p)
	if n < 4 || n > 16 {
		return false
	}
	for _, r := range p {
		if r < 0x20 || r == 0x7f {
			return false
		}
	}
	return true
}

func mac(secret []byte, salt, pw string) string {
	m := hmac.New(sha256.New, secret)
	m.Write([]byte(salt))
	m.Write([]byte{0})
	m.Write([]byte(pw))
	return hex.EncodeToString(m.Sum(nil))
}

// Hash returns "v1$<salt>$<mac>".
func Hash(secret []byte, pw string) string {
	s := make([]byte, 16)
	if _, err := rand.Read(s); err != nil {
		panic(err)
	}
	salt := hex.EncodeToString(s)
	return "v1$" + salt + "$" + mac(secret, salt, pw)
}

// Check compares in constant time.
func Check(secret []byte, stored, pw string) bool {
	parts := strings.Split(stored, "$")
	if len(parts) != 3 || parts[0] != "v1" {
		return false
	}
	return hmac.Equal([]byte(parts[2]), []byte(mac(secret, parts[1], pw)))
}
