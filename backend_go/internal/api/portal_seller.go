package api

import (
	"errors"
	"net/http"
	"strconv"

	"github.com/jackc/pgx/v5"

	"rdlive/internal/coinx"
)

// Mounted behind requireAuth + requireRole("coin_seller"). seller_transfer_coins()
// re-checks that the caller is an ACTIVE seller, so a suspended seller keeps read
// access (to see history) but cannot move a single coin.

// GET /v1/seller/me   balance check + today's limits
func (a *API) sellerMe(w http.ResponseWriter, r *http.Request) {
	var (
		pub, balance, sold, remaining, dailyLimit, perMax, received, soldTotal int64
		name, code, status                                                     string
		revenue                                                                float64
	)
	err := a.DB.QueryRow(r.Context(), `
		select public_id, display_name, display_code, status, balance, sold_today, remaining_today,
		       daily_limit_coins, per_transfer_max, received_total, sold_total, revenue_bdt::float8
		from v_seller_overview where user_id=$1`, userID(r.Context())).
		Scan(&pub, &name, &code, &status, &balance, &sold, &remaining, &dailyLimit, &perMax, &received, &soldTotal, &revenue)
	if err != nil {
		notFoundOr500(w, "sellerMe", err, "seller profile")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"public_id": pub, "display_name": name, "code": code, "status": status,
		"balance": balance, "sold_today": sold, "remaining_today": remaining,
		"daily_limit_coins": dailyLimit, "per_transfer_max": perMax,
		"received_total": received, "sold_total": soldTotal, "revenue_bdt": revenue,
	})
}

// GET /v1/seller/lookup?public_id=12345678
// Lets the seller confirm WHO will receive the coins before sending. Exposes no balances.
func (a *API) sellerLookup(w http.ResponseWriter, r *http.Request) {
	pid, err := strconv.ParseInt(r.URL.Query().Get("public_id"), 10, 64)
	if err != nil || !coinx.ValidPublicID(pid) {
		writeErr(w, http.StatusBadRequest, "bad_request", "invalid public_id")
		return
	}
	var (
		name, role, status, avatar string
	)
	err = a.DB.QueryRow(r.Context(), `
		select display_name, role::text, status::text, coalesce(avatar_url,'') from users where public_id=$1`, pid).
		Scan(&name, &role, &status, &avatar)
	if err != nil {
		notFoundOr500(w, "sellerLookup", err, "user")
		return
	}
	eligible := status == "active" && (role == "user" || role == "host" || role == "agency_owner")
	writeJSON(w, http.StatusOK, map[string]any{
		"public_id": pid, "display_name": name, "avatar_url": avatar, "role": role, "can_receive": eligible,
	})
}

// POST /v1/seller/transfers      Idempotency-Key required
// Body: {to_public_id, amount, price_bdt?, payment_method?, payment_ref?, note?}
// Seller -> Agency Owner | Host | User
func (a *API) sellerTransfer(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	seller := userID(ctx)
	key, ok := idemKey(w, r, seller)
	if !ok {
		return
	}
	var req struct {
		ToPublicID    int64    `json:"to_public_id"`
		Amount        int64    `json:"amount"`
		PriceBDT      *float64 `json:"price_bdt"`
		PaymentMethod string   `json:"payment_method"`
		PaymentRef    string   `json:"payment_ref"`
		Note          string   `json:"note"`
	}
	if !decode(w, r, &req) {
		return
	}
	note, noteOK := coinx.CleanNote(req.Note)
	ref, refOK := coinx.CleanPaymentRef(req.PaymentRef)
	if !coinx.ValidPublicID(req.ToPublicID) || !coinx.ValidAmount(req.Amount, 0) || !noteOK || !refOK {
		writeErr(w, http.StatusBadRequest, "bad_request", "invalid to_public_id, amount, note or payment_ref")
		return
	}
	if req.PaymentMethod != "" && !coinx.ValidPaymentMethod(req.PaymentMethod) {
		writeErr(w, http.StatusBadRequest, "bad_request", "payment_method must be bkash, nagad, rocket, bank or cash")
		return
	}
	if req.PriceBDT != nil && (*req.PriceBDT < 0 || *req.PriceBDT > 100_000_000) {
		writeErr(w, http.StatusBadRequest, "bad_request", "invalid price_bdt")
		return
	}
	// a payment reference without a method is meaningless (and breaks the per-method duplicate guard)
	if ref != "" && req.PaymentMethod == "" {
		writeErr(w, http.StatusBadRequest, "bad_request", "payment_method is required with payment_ref")
		return
	}

	to, err := a.userByPublicID(ctx, req.ToPublicID)
	if err != nil {
		notFoundOr500(w, "sellerTransfer lookup", err, "recipient")
		return
	}

	var existing int64
	err = a.DB.QueryRow(ctx, `select id from coin_transfers where idempotency_key=$1`, key).Scan(&existing)
	replay := err == nil
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		dbErr(w, "sellerTransfer replay check", err)
		return
	}

	var tid int64
	err = withRetry(func() error {
		return a.DB.QueryRow(ctx, `select seller_transfer_coins($1,$2,$3,$4::numeric,$5,$6,$7,$8)`,
			seller, to.ID, req.Amount, req.PriceBDT, nullable(req.PaymentMethod), nullable(ref), nullable(note), key).Scan(&tid)
	})
	if err != nil {
		dbErr(w, "seller_transfer_coins", err)
		return
	}
	var bal int64
	if err := a.DB.QueryRow(ctx, `select coins from wallets where user_id=$1`, seller).Scan(&bal); err != nil {
		dbErr(w, "sellerTransfer balance", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"transfer_id": tid, "amount": req.Amount, "seller_balance": bal, "replayed": replay,
		"recipient": map[string]any{"public_id": to.PublicID, "display_name": to.DisplayName, "role": to.Role},
	})
}

// GET /v1/seller/transfers?limit=&before_id=   coins received from Master + coins sold
func (a *API) sellerTransfers(w http.ResponseWriter, r *http.Request) {
	limit, before := paging(r)
	rows, err := a.DB.Query(r.Context(), `select `+transferCols+` from v_coin_transfers
		where (from_user_id=$1 or to_user_id=$1) and ($2::bigint=0 or id<$2::bigint)
		order by id desc limit $3`, userID(r.Context()), before, limit)
	if err != nil {
		dbErr(w, "sellerTransfers", err)
		return
	}
	items, err := scanTransfers(rows)
	if err != nil {
		dbErr(w, "sellerTransfers scan", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "next_before_id": nextCursor(items, limit)})
}

// GET /v1/host/earnings/today   live host earnings (diamonds update the moment a gift lands)
// Mounted behind requireAuth + requireRole("host").
func (a *API) hostEarningsToday(w http.ResponseWriter, r *http.Request) {
	var diamondsToday, gifts, liveSecs, diamondsTotal int64
	err := a.DB.QueryRow(r.Context(), `
		select coalesce(d.diamonds_earned,0), coalesce(d.gift_count,0), coalesce(d.live_seconds,0), w.diamonds
		from wallets w
		left join host_daily_stats d on d.host_id=w.user_id and d.stat_date=current_date
		where w.user_id=$1`, userID(r.Context())).Scan(&diamondsToday, &gifts, &liveSecs, &diamondsTotal)
	if err != nil {
		dbErr(w, "hostEarningsToday", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"diamonds_today": diamondsToday, "gifts_today": gifts, "live_seconds_today": liveSecs, "diamonds_balance": diamondsTotal,
	})
}
