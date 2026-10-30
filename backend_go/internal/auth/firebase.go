package auth

import (
	"context"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const defaultCertsURL = "https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com"

var ErrUnsupportedProvider = errors.New("unsupported sign-in provider")

// Identity is what we trust after verifying a Firebase ID token.
type Identity struct {
	UID      string // Firebase UID
	Provider string // 'google' | 'facebook' | 'phone'  (matches DB enum auth_provider)
	Email    string
	Name     string
	Picture  string
}

type Verifier interface {
	Verify(ctx context.Context, idToken string) (*Identity, error)
}

var providerMap = map[string]string{
	"google.com":   "google",
	"facebook.com": "facebook",
	"phone":        "phone",
}

// FirebaseVerifier verifies Firebase Auth ID tokens (RS256) against Google's
// public certificates. No service-account credentials are needed.
type FirebaseVerifier struct {
	projectID string
	certsURL  string
	hc        *http.Client

	mu        sync.Mutex
	keys      map[string]*rsa.PublicKey
	expires   time.Time
	lastFetch time.Time
}

func NewFirebaseVerifier(projectID string) *FirebaseVerifier {
	return &FirebaseVerifier{
		projectID: projectID,
		certsURL:  defaultCertsURL,
		hc:        &http.Client{Timeout: 10 * time.Second},
		keys:      map[string]*rsa.PublicKey{},
	}
}

// WithCertsURL overrides the certificate endpoint (tests).
func (v *FirebaseVerifier) WithCertsURL(u string) *FirebaseVerifier { v.certsURL = u; return v }

type fbClaims struct {
	jwt.RegisteredClaims
	Email    string `json:"email"`
	Name     string `json:"name"`
	Picture  string `json:"picture"`
	AuthTime int64  `json:"auth_time"`
	Firebase struct {
		SignInProvider string `json:"sign_in_provider"`
	} `json:"firebase"`
}

func (v *FirebaseVerifier) Verify(ctx context.Context, idToken string) (*Identity, error) {
	var c fbClaims
	_, err := jwt.ParseWithClaims(idToken, &c,
		func(t *jwt.Token) (any, error) {
			kid, _ := t.Header["kid"].(string)
			if kid == "" {
				return nil, errors.New("missing kid")
			}
			return v.key(ctx, kid)
		},
		jwt.WithValidMethods([]string{"RS256"}),
		jwt.WithAudience(v.projectID),
		jwt.WithIssuer("https://securetoken.google.com/"+v.projectID),
		jwt.WithExpirationRequired(),
		jwt.WithIssuedAt(),
		jwt.WithLeeway(30*time.Second),
	)
	if err != nil {
		return nil, fmt.Errorf("invalid firebase token: %w", err)
	}
	if c.Subject == "" || len(c.Subject) > 128 {
		return nil, errors.New("invalid firebase token: bad subject")
	}
	if c.AuthTime > time.Now().Add(30*time.Second).Unix() {
		return nil, errors.New("invalid firebase token: auth_time in future")
	}
	prov, ok := providerMap[c.Firebase.SignInProvider]
	if !ok {
		return nil, ErrUnsupportedProvider
	}
	return &Identity{UID: c.Subject, Provider: prov, Email: c.Email, Name: c.Name, Picture: c.Picture}, nil
}

func (v *FirebaseVerifier) key(ctx context.Context, kid string) (*rsa.PublicKey, error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	// Refresh when expired, or when kid is unknown (but at most every 30s so
	// random kids can't make us hammer Google).
	if time.Now().After(v.expires) || (v.keys[kid] == nil && time.Since(v.lastFetch) > 30*time.Second) {
		if err := v.refresh(ctx); err != nil && v.keys[kid] == nil {
			return nil, err
		}
	}
	k := v.keys[kid]
	if k == nil {
		return nil, errors.New("unknown signing key")
	}
	return k, nil
}

var maxAge = regexp.MustCompile(`max-age=(\d+)`)

func (v *FirebaseVerifier) refresh(ctx context.Context) error {
	v.lastFetch = time.Now()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, v.certsURL, nil)
	if err != nil {
		return err
	}
	res, err := v.hc.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return fmt.Errorf("fetch certs: status %d", res.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if err != nil {
		return err
	}
	var pems map[string]string
	if err := json.Unmarshal(body, &pems); err != nil {
		return err
	}
	keys := make(map[string]*rsa.PublicKey, len(pems))
	for kid, p := range pems {
		blk, _ := pem.Decode([]byte(p))
		if blk == nil {
			continue
		}
		cert, err := x509.ParseCertificate(blk.Bytes)
		if err != nil {
			continue
		}
		if pk, ok := cert.PublicKey.(*rsa.PublicKey); ok {
			keys[kid] = pk
		}
	}
	if len(keys) == 0 {
		return errors.New("no usable certificates")
	}
	ttl := time.Hour
	if m := maxAge.FindStringSubmatch(res.Header.Get("Cache-Control")); m != nil {
		if s, err := strconv.Atoi(m[1]); err == nil && s > 60 {
			ttl = time.Duration(s) * time.Second
		}
	}
	v.keys = keys
	v.expires = time.Now().Add(ttl)
	return nil
}
