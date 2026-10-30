package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"strconv"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const issuer = "rdlive"

// Tokens issues and parses rdlive's own short-lived access JWTs.
type Tokens struct {
	secret []byte
	ttl    time.Duration
}

func NewTokens(secret string, ttl time.Duration) *Tokens {
	return &Tokens{secret: []byte(secret), ttl: ttl}
}

type claims struct {
	Role string `json:"role"`
	jwt.RegisteredClaims
}

func (t *Tokens) Issue(userID int64, role string) (string, error) {
	now := time.Now()
	c := claims{
		Role: role,
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   strconv.FormatInt(userID, 10),
			Issuer:    issuer,
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(t.ttl)),
		},
	}
	return jwt.NewWithClaims(jwt.SigningMethodHS256, c).SignedString(t.secret)
}

func (t *Tokens) TTL() time.Duration { return t.ttl }

func (t *Tokens) Parse(s string) (userID int64, role string, err error) {
	var c claims
	_, err = jwt.ParseWithClaims(s, &c,
		func(*jwt.Token) (any, error) { return t.secret, nil },
		jwt.WithValidMethods([]string{"HS256"}),
		jwt.WithIssuer(issuer),
		jwt.WithExpirationRequired(),
	)
	if err != nil {
		return 0, "", err
	}
	userID, err = strconv.ParseInt(c.Subject, 10, 64)
	return userID, c.Role, err
}

// NewRefreshToken returns a random opaque token and its SHA-256 hash.
// Only the hash is stored in the database.
func NewRefreshToken() (raw, hash string) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	raw = base64.RawURLEncoding.EncodeToString(b)
	return raw, HashToken(raw)
}

func HashToken(raw string) string {
	h := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(h[:])
}
