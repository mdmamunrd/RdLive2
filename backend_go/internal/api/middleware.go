package api

import (
	"context"
	"net/http"
	"strings"
	"sync"
	"time"

	"golang.org/x/time/rate"
)

type ctxKey int

const (
	ctxUserID ctxKey = iota
	ctxRole
)

func userID(ctx context.Context) int64 { v, _ := ctx.Value(ctxUserID).(int64); return v }

func (a *API) requireAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !ok || tok == "" {
			writeErr(w, http.StatusUnauthorized, "unauthorized", "missing bearer token")
			return
		}
		uid, role, err := a.Tokens.Parse(tok)
		if err != nil {
			writeErr(w, http.StatusUnauthorized, "unauthorized", "invalid or expired token")
			return
		}
		// Bans/suspensions take effect immediately, not at token expiry.
		var status string
		if err := a.DB.QueryRow(r.Context(), `select status::text from users where id=$1`, uid).Scan(&status); err != nil {
			writeErr(w, http.StatusUnauthorized, "unauthorized", "unknown user")
			return
		}
		if status != "active" {
			writeErr(w, http.StatusForbidden, "account_blocked", "account is "+status)
			return
		}
		ctx := context.WithValue(r.Context(), ctxUserID, uid)
		ctx = context.WithValue(ctx, ctxRole, role)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// rateLimit is a small per-IP token bucket (single instance). For multiple
// API replicas move this to Redis.
func rateLimit(perSec float64, burst int) func(http.Handler) http.Handler {
	type entry struct {
		l    *rate.Limiter
		seen time.Time
	}
	var (
		mu sync.Mutex
		m  = map[string]*entry{}
	)
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			ip := clientIP(r)
			mu.Lock()
			if len(m) > 10000 {
				for k, e := range m {
					if time.Since(e.seen) > 10*time.Minute {
						delete(m, k)
					}
				}
			}
			e, ok := m[ip]
			if !ok {
				e = &entry{l: rate.NewLimiter(rate.Limit(perSec), burst)}
				m[ip] = e
			}
			e.seen = time.Now()
			allowed := e.l.Allow()
			mu.Unlock()
			if !allowed {
				w.Header().Set("Retry-After", "10")
				writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many requests")
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}
