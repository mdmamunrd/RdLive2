package api

import (
	"errors"
	"log"
	"net/http"
	"regexp"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"rdlive/internal/coinx"
)

var idemRe = regexp.MustCompile(`^[A-Za-z0-9_\-:.]{8,64}$`)

// GET /v1/gifts
func (a *API) listGifts(w http.ResponseWriter, r *http.Request) {
	rows, err := a.DB.Query(r.Context(), `
		select id,name,category::text,price_coins,coalesce(icon_url,''),coalesce(animation_url,''),
		       coalesce(animation_type,''),is_full_screen,min_level
		from gifts where is_active order by sort_order,id`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "try again")
		return
	}
	defer rows.Close()
	type gift struct {
		ID            int    `json:"id"`
		Name          string `json:"name"`
		Category      string `json:"category"`
		PriceCoins    int64  `json:"price_coins"`
		IconURL       string `json:"icon_url"`
		AnimationURL  string `json:"animation_url"`
		AnimationType string `json:"animation_type"`
		FullScreen    bool   `json:"is_full_screen"`
		MinLevel      int    `json:"min_level"`
	}
	out := []gift{}
	for rows.Next() {
		var g gift
		if err := rows.Scan(&g.ID, &g.Name, &g.Category, &g.PriceCoins, &g.IconURL, &g.AnimationURL, &g.AnimationType, &g.FullScreen, &g.MinLevel); err != nil {
			writeErr(w, http.StatusInternalServerError, "internal", "try again")
			return
		}
		out = append(out, g)
	}
	writeJSON(w, http.StatusOK, map[string]any{"gifts": out})
}

// POST /v1/gifts/send
// Header: Idempotency-Key (8-64 chars, unique per tap; reuse it when retrying)
// Body:   {receiver_id, room_id?, gift_id, quantity}
func (a *API) sendGift(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	sender := userID(ctx)

	key := r.Header.Get("Idempotency-Key")
	if !idemRe.MatchString(key) {
		writeErr(w, http.StatusBadRequest, "idempotency_key_required", "send an Idempotency-Key header (8-64 chars)")
		return
	}
	var req struct {
		ReceiverID int64  `json:"receiver_id"`
		RoomID     *int64 `json:"room_id"`
		GiftID     int    `json:"gift_id"`
		Quantity   int    `json:"quantity"`
	}
	if !decode(w, r, &req) {
		return
	}
	if req.Quantity < 1 || req.Quantity > 9999 || req.GiftID <= 0 || req.ReceiverID <= 0 {
		writeErr(w, http.StatusBadRequest, "bad_request", "invalid gift_id, receiver_id or quantity")
		return
	}
	if req.ReceiverID == sender {
		writeErr(w, http.StatusBadRequest, "self_gift", "you cannot gift yourself")
		return
	}

	// Namespaced by sender so one user can never collide with / probe another's keys.
	idem := "u" + itoa(sender) + ":" + key

	var existing int64
	err := a.DB.QueryRow(ctx, `select id from gift_transactions where idempotency_key=$1`, idem).Scan(&existing)
	replay := err == nil
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		writeErr(w, http.StatusInternalServerError, "internal", "try again")
		return
	}

	if !replay {
		var okRecv bool
		if err := a.DB.QueryRow(ctx, `select exists(select 1 from users where id=$1 and status='active')`, req.ReceiverID).Scan(&okRecv); err != nil || !okRecv {
			writeErr(w, http.StatusNotFound, "receiver_not_found", "receiver not available")
			return
		}
		if req.RoomID != nil {
			var live bool
			if err := a.DB.QueryRow(ctx, `select exists(select 1 from live_rooms where id=$1 and status='live')`, *req.RoomID).Scan(&live); err != nil || !live {
				writeErr(w, http.StatusNotFound, "room_not_live", "room is not live")
				return
			}
		}
	}

	var txID int64
	err = a.DB.QueryRow(ctx, `select send_gift($1,$2,$3,$4,$5,$6)`,
		sender, req.ReceiverID, req.RoomID, req.GiftID, req.Quantity, idem).Scan(&txID)
	if err != nil {
		a.giftError(w, err)
		return
	}

	var spent, earned, coins int64
	if err := a.DB.QueryRow(ctx, `
		select g.coins_spent, g.diamonds_earned, w.coins
		from gift_transactions g join wallets w on w.user_id=g.sender_id where g.id=$1`, txID).Scan(&spent, &earned, &coins); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "gift sent; refresh wallet")
		return
	}

	// The realtime 'gift' event is emitted by send_gift() itself (pg_notify on room_events),
	// so it also fires if this process dies right after COMMIT and is never sent twice.
	writeJSON(w, http.StatusOK, map[string]any{
		"gift_tx_id": txID, "coins_spent": spent, "diamonds_earned": earned, "coins_balance": coins, "replayed": replay,
	})
}

func (a *API) giftError(w http.ResponseWriter, err error) {
	var pe *pgconn.PgError
	if errors.As(err, &pe) {
		switch {
		case strings.HasPrefix(pe.Message, "insufficient"):
			writeErr(w, http.StatusPaymentRequired, "insufficient_balance", "not enough coins")
			return
		case strings.HasPrefix(pe.Message, "gift not available"):
			writeErr(w, http.StatusNotFound, "gift_not_found", "gift not available")
			return
		case strings.HasPrefix(pe.Message, "level too low"):
			writeErr(w, http.StatusForbidden, "level_too_low", "your level is too low for this gift")
			return
		case strings.HasPrefix(pe.Message, "cannot gift yourself"):
			writeErr(w, http.StatusBadRequest, "self_gift", "you cannot gift yourself")
			return
		case pe.Code == "23503":
			writeErr(w, http.StatusNotFound, "not_found", "receiver or room not found")
			return
		case pe.Code == "23514":
			writeErr(w, http.StatusBadRequest, "bad_request", "invalid quantity")
			return
		}
	}
	if errors.As(err, &pe) {
		if st, code, msg, ok := coinx.MapError(pe.Message, pe.Code); ok {
			writeErr(w, st, code, msg)
			return
		}
	}
	log.Printf("send_gift: %v", err)
	writeErr(w, http.StatusInternalServerError, "internal", "try again")
}

func itoa(n int64) string {
	const digits = "0123456789"
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = digits[n%10]
		n /= 10
	}
	return string(b[i:])
}
