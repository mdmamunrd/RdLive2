package api

import (
	"context"
	"errors"
	"log"
	"net/http"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"rdlive/internal/coinx"
)

// requireRole lets a request through only if the user's CURRENT role in the
// database is one of roles. The role claim inside the JWT is deliberately
// ignored: demoting a seller or admin must take effect immediately, not when
// the 15-minute access token expires.
func (a *API) requireRole(roles ...string) func(http.Handler) http.Handler {
	allowed := make(map[string]struct{}, len(roles))
	for _, r := range roles {
		allowed[r] = struct{}{}
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			var role string
			err := a.DB.QueryRow(r.Context(), `select role::text from users where id=$1`, userID(r.Context())).Scan(&role)
			if err != nil {
				writeErr(w, http.StatusUnauthorized, "unauthorized", "unknown user")
				return
			}
			if _, ok := allowed[role]; !ok {
				writeErr(w, http.StatusForbidden, "forbidden", "you are not allowed to use this portal")
				return
			}
			next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), ctxRole, role)))
		})
	}
}

// portalCORS allows the web portals (served from PORTAL_ORIGINS) to call the API
// from a browser. Requests without an Origin header (the mobile app) are untouched,
// and an origin that is not on the list gets no CORS headers at all.
// Tokens travel in the Authorization header, never in cookies, so there is no CSRF surface.
func portalCORS(origins []string) func(http.Handler) http.Handler {
	set := make(map[string]struct{}, len(origins))
	for _, o := range origins {
		set[o] = struct{}{}
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if origin := r.Header.Get("Origin"); origin != "" {
				if _, ok := set[origin]; ok {
					h := w.Header()
					h.Set("Access-Control-Allow-Origin", origin)
					h.Add("Vary", "Origin")
					h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, Idempotency-Key")
					h.Set("Access-Control-Allow-Methods", "GET, POST, PATCH, OPTIONS")
					h.Set("Access-Control-Max-Age", "600")
				}
				if r.Method == http.MethodOptions {
					w.WriteHeader(http.StatusNoContent)
					return
				}
			}
			next.ServeHTTP(w, r)
		})
	}
}

// ---- shared helpers --------------------------------------------------------

// dbErr maps a database error to an HTTP response. Unknown errors are logged
// and answered with a generic 500.
func dbErr(w http.ResponseWriter, op string, err error) {
	var pe *pgconn.PgError
	if errors.As(err, &pe) {
		if st, code, msg, ok := coinx.MapError(pe.Message, pe.Code); ok {
			writeErr(w, st, code, msg)
			return
		}
	}
	log.Printf("%s: %v", op, err)
	writeErr(w, http.StatusInternalServerError, "internal", "try again")
}

// withRetry runs fn once more if PostgreSQL aborted it for a deadlock or
// serialization failure. The SQL functions are atomic, so a retry is safe.
func withRetry(fn func() error) error {
	err := fn()
	var pe *pgconn.PgError
	if errors.As(err, &pe) && coinx.Retryable(pe.Code) {
		return fn()
	}
	return err
}

// idemKey reads and namespaces the Idempotency-Key header.
func idemKey(w http.ResponseWriter, r *http.Request, actor int64) (string, bool) {
	k := r.Header.Get("Idempotency-Key")
	if !coinx.ValidIdemKey(k) {
		writeErr(w, http.StatusBadRequest, "idempotency_key_required", "send an Idempotency-Key header (8-64 chars: letters, digits, _ - : .)")
		return "", false
	}
	return coinx.NamespaceKey(actor, k), true
}

func paging(r *http.Request) (limit int, before int64) {
	limit, _ = strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 || limit > 100 {
		limit = 30
	}
	before, _ = strconv.ParseInt(r.URL.Query().Get("before_id"), 10, 64)
	return limit, before
}

type userRef struct {
	ID          int64
	PublicID    int64
	DisplayName string
	Role        string
	Status      string
}

// userByPublicID resolves the 8-digit id a person types into the portal.
func (a *API) userByPublicID(ctx context.Context, publicID int64) (userRef, error) {
	var u userRef
	err := a.DB.QueryRow(ctx, `
		select id, public_id, display_name, role::text, status::text from users where public_id=$1`, publicID).
		Scan(&u.ID, &u.PublicID, &u.DisplayName, &u.Role, &u.Status)
	return u, err
}

func notFoundOr500(w http.ResponseWriter, op string, err error, what string) {
	if errors.Is(err, pgx.ErrNoRows) {
		writeErr(w, http.StatusNotFound, "not_found", what+" not found")
		return
	}
	dbErr(w, op, err)
}

// ---- transfer list item (shared by admin and seller portals) --------------

type transferItem struct {
	ID            int64     `json:"id"`
	Kind          string    `json:"kind"`
	Amount        int64     `json:"amount"`
	PriceBDT      *float64  `json:"price_bdt,omitempty"`
	PaymentMethod *string   `json:"payment_method,omitempty"`
	PaymentRef    *string   `json:"payment_ref,omitempty"`
	Note          *string   `json:"note,omitempty"`
	CreatedAt     time.Time `json:"created_at"`
	FromPublicID  *int64    `json:"from_public_id,omitempty"`
	FromName      *string   `json:"from_name,omitempty"`
	ToPublicID    *int64    `json:"to_public_id,omitempty"`
	ToName        *string   `json:"to_name,omitempty"`
	ToRole        *string   `json:"to_role,omitempty"`
}

const transferCols = `id, kind::text, amount, price_bdt::float8, payment_method, payment_ref, note, created_at,
	from_public_id, from_name, to_public_id, to_name, to_role::text`

func scanTransfers(rows pgx.Rows) ([]transferItem, error) {
	defer rows.Close()
	out := []transferItem{}
	for rows.Next() {
		var t transferItem
		if err := rows.Scan(&t.ID, &t.Kind, &t.Amount, &t.PriceBDT, &t.PaymentMethod, &t.PaymentRef, &t.Note, &t.CreatedAt,
			&t.FromPublicID, &t.FromName, &t.ToPublicID, &t.ToName, &t.ToRole); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

func nextCursor(items []transferItem, limit int) int64 {
	if len(items) == limit {
		return items[len(items)-1].ID
	}
	return 0
}
