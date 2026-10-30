package api

import (
	"encoding/json"
	"net"
	"net/http"
	"net/netip"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/jackc/pgx/v5/pgxpool"

	"rdlive/internal/auth"
	"rdlive/internal/config"
	"rdlive/internal/media"
	"rdlive/internal/payments"
	"rdlive/internal/realtime"
)

type Deps struct {
	Cfg       config.Config
	DB        *pgxpool.Pool
	Verifier  auth.Verifier
	Tokens    *auth.Tokens
	Providers map[string]payments.Provider
	Publisher realtime.Publisher
	Hub       *realtime.Hub // WebSocket connections (created if nil)
	Media     media.Store   // chat image storage (nil = image chat disabled)
}

type API struct{ Deps }

// New returns just the HTTP handler. Use NewServer when you also want the background workers
// (database listener, PK ticker); main.go does.
func New(d Deps) http.Handler { return NewServer(d).Handler() }

func (a *API) router() http.Handler {
	r := chi.NewRouter()
	r.Use(middleware.RequestID)
	// NOTE: RealIP trusts X-Forwarded-For / X-Real-IP. Deploy behind a proxy
	// that overwrites those headers, otherwise IP bans/rate limits can be spoofed.
	r.Use(middleware.RealIP)
	r.Use(middleware.Recoverer)
	r.Use(middleware.Timeout(30 * time.Second))
	r.Use(portalCORS(a.Cfg.PortalOrigins)) // no-op for the mobile app (no Origin header)

	r.Get("/healthz", func(w http.ResponseWriter, r *http.Request) {
		if err := a.DB.Ping(r.Context()); err != nil {
			writeErr(w, http.StatusServiceUnavailable, "db_down", "database unavailable")
			return
		}
		clients, rooms, dropped := a.Hub.Stats()
		writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "ws_clients": clients, "ws_rooms": rooms, "ws_dropped_slow": dropped})
	})

	authLimit := rateLimit(10.0/60.0, 10) // ~10 req/min per IP
	portalLimit := rateLimit(2, 20)       // portal writes: ~2 req/s per IP, burst 20
	joinLimit := rateLimit(1, 10)         // room password guessing
	chatLimit := rateLimit(20, 100)       // generous: mobile carriers share IPs; the per-user limit lives in SQL
	mediaLimit := rateLimit(1, 15)

	r.Route("/v1", func(r chi.Router) {
		r.With(authLimit).Post("/auth/social", a.socialLogin)
		r.With(authLimit).Post("/auth/refresh", a.refresh)

		r.Group(func(r chi.Router) {
			r.Use(a.requireAuth)
			r.Get("/me", a.me)
			r.Get("/wallet", a.wallet)
			r.Get("/wallet/ledger", a.ledger)
			r.Get("/recharge/packages", a.packages)
			r.Post("/recharge/orders", a.createOrder)
			r.Get("/recharge/orders/{id}", a.getOrder)
			r.Get("/gifts", a.listGifts)
			r.Post("/gifts/send", a.sendGift)

			// Host earnings (diamonds update the moment a gift lands)
			r.With(a.requireRole("host")).Get("/host/earnings/today", a.hostEarningsToday)

			// ---- Home feed + live rooms ----
			r.Route("/rooms", func(r chi.Router) {
				r.Get("/", a.roomFeed) // ?tab=discover|new|follow
				r.With(portalLimit).Post("/", a.roomCreate)
				r.Route("/{id}", func(r chi.Router) {
					r.Get("/", a.roomSnapshot)
					r.Patch("/", a.roomPatch)
					r.With(joinLimit).Post("/join", a.roomJoin)
					r.Post("/leave", a.roomLeave)
					r.Post("/end", a.roomEnd)
					r.Post("/seats/request", a.seatRequest)
					r.Delete("/seats/request", a.seatRequestCancel)
					r.Post("/seats/leave", a.seatLeave)
					r.Patch("/seats/me", a.seatMedia)
					r.Post("/seats/{n}/lock", a.seatLock(true))
					r.Post("/seats/{n}/unlock", a.seatLock(false))
					r.Post("/requests/{rid}", a.seatResolve)
					r.Post("/members/{uid}/{action}", a.memberAction)
				})
			})
			r.Route("/pk", func(r chi.Router) {
				r.Post("/", a.pkCreate)
				r.Get("/{id}", a.pkGet)
				r.Post("/{id}/{action}", a.pkAction)
			})

			// ---- follows / blocks / profile card ----
			r.Get("/me/following", a.myFollowing)
			r.Get("/me/followers", a.myFollowers)
			r.Get("/users/{publicID}", a.userCard)
			r.Post("/users/{publicID}/follow", a.followUser)
			r.Delete("/users/{publicID}/follow", a.unfollowUser)
			r.Post("/users/{publicID}/block", a.blockUser)
			r.Delete("/users/{publicID}/block", a.unblockUser)

			// ---- 1-on-1 chat ----
			r.Route("/chat", func(r chi.Router) {
				r.Get("/unread", a.chatUnread)
				r.With(chatLimit).Post("/conversations", a.chatOpen)
				r.Get("/conversations", a.chatInbox)
				r.Route("/conversations/{id}", func(r chi.Router) {
					r.Get("/messages", a.chatMessages)
					r.With(chatLimit).Post("/messages", a.chatSend)
					r.With(chatLimit).Post("/read", a.chatRead)
					r.Patch("/", a.chatMute)
					r.Delete("/", a.chatClear)
				})
				r.With(mediaLimit).Post("/media", a.mediaCreate)
				r.With(mediaLimit).Post("/media/{id}/complete", a.mediaComplete)
			})
			r.Put("/media/{id}/content", a.mediaUploadLocal)
			r.Get("/media/{id}", a.mediaGet)

			// Master (Super Admin) web portal
			r.Route("/admin", func(r chi.Router) {
				r.Use(a.requireRole("super_admin"))
				r.Get("/sellers", a.adminListSellers)
				r.With(portalLimit).Post("/sellers", a.adminCreateSeller)
				r.With(portalLimit).Patch("/sellers/{id}", a.adminUpdateSeller)
				r.With(portalLimit).Post("/coins/mint", a.adminMint)
				r.With(portalLimit).Post("/coins/reclaim", a.adminReclaim)
				r.Get("/coins/transfers", a.adminTransfers)
				r.Get("/coins/audit", a.adminAudit)
				r.Get("/wallets/{publicID}", a.adminWallet)
			})

			// Coin Seller web portal
			r.Route("/seller", func(r chi.Router) {
				r.Use(a.requireRole("coin_seller"))
				r.Get("/me", a.sellerMe)
				r.Get("/lookup", a.sellerLookup)
				r.Get("/transfers", a.sellerTransfers)
				r.With(portalLimit).Post("/transfers", a.sellerTransfer)
			})
		})
	})

	// Gateway callbacks (no user auth: authenticity comes from signature /
	// server-to-server verification inside each provider).
	r.HandleFunc("/webhooks/{provider}", a.paymentWebhook)
	r.Get("/pay/return", a.payReturn)
	return r
}

// handler puts the WebSocket endpoint OUTSIDE the router: it must not run under the 30 s request
// timeout, and after the upgrade the connection belongs to the ws package.
func (a *API) handler() http.Handler {
	mux := http.NewServeMux()
	// RealIP so the per-IP limit keys on the client, not on the reverse proxy (same trust note as router()).
	mux.Handle("GET /v1/ws", middleware.RealIP(rateLimit(2, 30)(http.HandlerFunc(a.wsHandler))))
	mux.Handle("/", a.router())
	return mux
}

// ---- helpers ----

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, map[string]any{"error": map[string]string{"code": code, "message": msg}})
}

func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
	if err := json.NewDecoder(r.Body).Decode(v); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "invalid JSON body")
		return false
	}
	return true
}

func clientIP(r *http.Request) string {
	host := r.RemoteAddr
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	if a, err := netip.ParseAddr(host); err == nil {
		return a.String()
	}
	return ""
}
