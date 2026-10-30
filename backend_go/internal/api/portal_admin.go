package api

import (
	"encoding/json"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"

	"rdlive/internal/coinx"
)

// All handlers here are mounted behind requireAuth + requireRole("super_admin").
// The SQL functions check super_admin again, so a routing mistake cannot mint coins.

// POST /v1/admin/sellers   {public_id, code, daily_limit_coins?, per_transfer_max?}
func (a *API) adminCreateSeller(w http.ResponseWriter, r *http.Request) {
	var req struct {
		PublicID        int64  `json:"public_id"`
		Code            string `json:"code"`
		DailyLimitCoins int64  `json:"daily_limit_coins"`
		PerTransferMax  int64  `json:"per_transfer_max"`
	}
	if !decode(w, r, &req) {
		return
	}
	if !coinx.ValidPublicID(req.PublicID) || !coinx.ValidSellerCode(req.Code) {
		writeErr(w, http.StatusBadRequest, "bad_request", "invalid public_id or code (A-Z, 0-9, _ -, 3-20 chars)")
		return
	}
	if req.DailyLimitCoins == 0 {
		req.DailyLimitCoins = coinx.DefaultDailyLimit
	}
	if req.PerTransferMax == 0 {
		req.PerTransferMax = coinx.DefaultPerTransferMax
	}
	if !coinx.ValidAmount(req.DailyLimitCoins, 0) || !coinx.ValidAmount(req.PerTransferMax, 0) || req.PerTransferMax > req.DailyLimitCoins {
		writeErr(w, http.StatusBadRequest, "bad_request", "limits must be positive and per_transfer_max <= daily_limit_coins")
		return
	}
	u, err := a.userByPublicID(r.Context(), req.PublicID)
	if err != nil {
		notFoundOr500(w, "adminCreateSeller lookup", err, "user")
		return
	}
	err = withRetry(func() error {
		_, e := a.DB.Exec(r.Context(), `select admin_create_seller($1,$2,$3,$4,$5)`,
			userID(r.Context()), u.ID, req.Code, req.DailyLimitCoins, req.PerTransferMax)
		return e
	})
	if err != nil {
		dbErr(w, "admin_create_seller", err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"seller_id": u.ID, "public_id": u.PublicID, "display_name": u.DisplayName, "code": req.Code})
}

// GET /v1/admin/sellers
func (a *API) adminListSellers(w http.ResponseWriter, r *http.Request) {
	rows, err := a.DB.Query(r.Context(), `
		select user_id, public_id, display_name, display_code, status, daily_limit_coins, per_transfer_max,
		       balance, sold_today, remaining_today, received_total, sold_total, revenue_bdt::float8
		from v_seller_overview order by display_code`)
	if err != nil {
		dbErr(w, "adminListSellers", err)
		return
	}
	defer rows.Close()
	type seller struct {
		SellerID        int64   `json:"seller_id"`
		PublicID        int64   `json:"public_id"`
		DisplayName     string  `json:"display_name"`
		Code            string  `json:"code"`
		Status          string  `json:"status"`
		DailyLimitCoins int64   `json:"daily_limit_coins"`
		PerTransferMax  int64   `json:"per_transfer_max"`
		Balance         int64   `json:"balance"`
		SoldToday       int64   `json:"sold_today"`
		RemainingToday  int64   `json:"remaining_today"`
		ReceivedTotal   int64   `json:"received_total"`
		SoldTotal       int64   `json:"sold_total"`
		RevenueBDT      float64 `json:"revenue_bdt"`
	}
	out := []seller{}
	for rows.Next() {
		var s seller
		if err := rows.Scan(&s.SellerID, &s.PublicID, &s.DisplayName, &s.Code, &s.Status, &s.DailyLimitCoins, &s.PerTransferMax,
			&s.Balance, &s.SoldToday, &s.RemainingToday, &s.ReceivedTotal, &s.SoldTotal, &s.RevenueBDT); err != nil {
			dbErr(w, "adminListSellers scan", err)
			return
		}
		out = append(out, s)
	}
	if err := rows.Err(); err != nil {
		dbErr(w, "adminListSellers rows", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"sellers": out})
}

// PATCH /v1/admin/sellers/{id}   {status?, daily_limit_coins?, per_transfer_max?}   ({id} = seller_id)
func (a *API) adminUpdateSeller(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(chi.URLParam(r, "id"), 10, 64)
	if err != nil || id <= 0 {
		writeErr(w, http.StatusBadRequest, "bad_request", "invalid seller id")
		return
	}
	var req struct {
		Status          *string `json:"status"`
		DailyLimitCoins *int64  `json:"daily_limit_coins"`
		PerTransferMax  *int64  `json:"per_transfer_max"`
	}
	if !decode(w, r, &req) {
		return
	}
	if req.Status == nil && req.DailyLimitCoins == nil && req.PerTransferMax == nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "nothing to update")
		return
	}
	if req.Status != nil && *req.Status != coinx.StatusActive && *req.Status != coinx.StatusSuspended {
		writeErr(w, http.StatusBadRequest, "bad_request", "status must be active or suspended")
		return
	}
	if (req.DailyLimitCoins != nil && !coinx.ValidAmount(*req.DailyLimitCoins, 0)) ||
		(req.PerTransferMax != nil && !coinx.ValidAmount(*req.PerTransferMax, 0)) {
		writeErr(w, http.StatusBadRequest, "bad_request", "limits must be positive")
		return
	}
	err = withRetry(func() error {
		_, e := a.DB.Exec(r.Context(), `select admin_update_seller($1,$2,$3,$4,$5)`,
			userID(r.Context()), id, req.Status, req.DailyLimitCoins, req.PerTransferMax)
		return e
	})
	if err != nil {
		dbErr(w, "admin_update_seller", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// POST /v1/admin/coins/mint      Idempotency-Key required
// Body: {seller_id, amount, note?}     Master -> Seller
func (a *API) adminMint(w http.ResponseWriter, r *http.Request) {
	admin := userID(r.Context())
	key, ok := idemKey(w, r, admin)
	if !ok {
		return
	}
	var req struct {
		SellerID int64  `json:"seller_id"`
		Amount   int64  `json:"amount"`
		Note     string `json:"note"`
	}
	if !decode(w, r, &req) {
		return
	}
	note, noteOK := coinx.CleanNote(req.Note)
	if req.SellerID <= 0 || !coinx.ValidAmount(req.Amount, 0) || !noteOK {
		writeErr(w, http.StatusBadRequest, "bad_request", "invalid seller_id, amount or note")
		return
	}
	var tid int64
	err := withRetry(func() error {
		return a.DB.QueryRow(r.Context(), `select admin_mint_coins($1,$2,$3,$4,$5)`,
			admin, req.SellerID, req.Amount, nullable(note), key).Scan(&tid)
	})
	if err != nil {
		dbErr(w, "admin_mint_coins", err)
		return
	}
	var bal int64
	if err := a.DB.QueryRow(r.Context(), `select coins from wallets where user_id=$1`, req.SellerID).Scan(&bal); err != nil {
		dbErr(w, "adminMint balance", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"transfer_id": tid, "seller_balance": bal})
}

// POST /v1/admin/coins/reclaim   Idempotency-Key required
// Body: {public_id, amount, reason}     burns coins from any wallet (fraud, chargeback, mistake)
func (a *API) adminReclaim(w http.ResponseWriter, r *http.Request) {
	admin := userID(r.Context())
	key, ok := idemKey(w, r, admin)
	if !ok {
		return
	}
	var req struct {
		PublicID int64  `json:"public_id"`
		Amount   int64  `json:"amount"`
		Reason   string `json:"reason"`
	}
	if !decode(w, r, &req) {
		return
	}
	reason, reasonOK := coinx.CleanReason(req.Reason)
	if !coinx.ValidPublicID(req.PublicID) || !coinx.ValidAmount(req.Amount, 0) || !reasonOK || len(reason) < 3 {
		writeErr(w, http.StatusBadRequest, "bad_request", "invalid public_id, amount or reason (min 3 chars)")
		return
	}
	u, err := a.userByPublicID(r.Context(), req.PublicID)
	if err != nil {
		notFoundOr500(w, "adminReclaim lookup", err, "user")
		return
	}
	var tid int64
	err = withRetry(func() error {
		return a.DB.QueryRow(r.Context(), `select admin_reclaim_coins($1,$2,$3,$4,$5)`,
			admin, u.ID, req.Amount, reason, key).Scan(&tid)
	})
	if err != nil {
		dbErr(w, "admin_reclaim_coins", err)
		return
	}
	var bal int64
	if err := a.DB.QueryRow(r.Context(), `select coins from wallets where user_id=$1`, u.ID).Scan(&bal); err != nil {
		dbErr(w, "adminReclaim balance", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"transfer_id": tid, "balance": bal})
}

// GET /v1/admin/coins/transfers?kind=mint|seller_sale|reclaim&limit=&before_id=
func (a *API) adminTransfers(w http.ResponseWriter, r *http.Request) {
	limit, before := paging(r)
	kind := r.URL.Query().Get("kind")
	if kind != "" && kind != "mint" && kind != "seller_sale" && kind != "reclaim" {
		writeErr(w, http.StatusBadRequest, "bad_request", "kind must be mint, seller_sale or reclaim")
		return
	}
	rows, err := a.DB.Query(r.Context(), `select `+transferCols+` from v_coin_transfers
		where ($1='' or kind::text=$1) and ($2::bigint=0 or id<$2::bigint)
		order by id desc limit $3`, kind, before, limit)
	if err != nil {
		dbErr(w, "adminTransfers", err)
		return
	}
	items, err := scanTransfers(rows)
	if err != nil {
		dbErr(w, "adminTransfers scan", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "next_before_id": nextCursor(items, limit)})
}

// GET /v1/admin/wallets/{publicID}   balance check + last 20 coin movements
func (a *API) adminWallet(w http.ResponseWriter, r *http.Request) {
	pid, err := strconv.ParseInt(chi.URLParam(r, "publicID"), 10, 64)
	if err != nil || !coinx.ValidPublicID(pid) {
		writeErr(w, http.StatusBadRequest, "bad_request", "invalid public id")
		return
	}
	var (
		uid                int64
		name, role, status string
		coins, diamonds    int64
	)
	err = a.DB.QueryRow(r.Context(), `
		select user_id, display_name, role::text, account_status::text, coins, diamonds
		from user_wallets where public_id=$1`, pid).Scan(&uid, &name, &role, &status, &coins, &diamonds)
	if err != nil {
		notFoundOr500(w, "adminWallet", err, "user")
		return
	}
	rows, err := a.DB.Query(r.Context(), `
		select id, amount, balance_after, tx_type::text, created_at, transfer_id, counterparty_id
		from coin_transactions where user_id=$1 order by id desc limit 20`, uid)
	if err != nil {
		dbErr(w, "adminWallet ledger", err)
		return
	}
	defer rows.Close()
	type mv struct {
		ID             int64     `json:"id"`
		Amount         int64     `json:"amount"`
		BalanceAfter   int64     `json:"balance_after"`
		Type           string    `json:"type"`
		CreatedAt      time.Time `json:"created_at"`
		TransferID     *int64    `json:"transfer_id,omitempty"`
		CounterpartyID *int64    `json:"counterparty_id,omitempty"`
	}
	moves := []mv{}
	for rows.Next() {
		var m mv
		if err := rows.Scan(&m.ID, &m.Amount, &m.BalanceAfter, &m.Type, &m.CreatedAt, &m.TransferID, &m.CounterpartyID); err != nil {
			dbErr(w, "adminWallet scan", err)
			return
		}
		moves = append(moves, m)
	}
	if err := rows.Err(); err != nil {
		dbErr(w, "adminWallet rows", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"user_id": uid, "public_id": pid, "display_name": name, "role": role, "status": status,
		"coins": coins, "diamonds": diamonds, "recent_coin_movements": moves,
	})
}

// GET /v1/admin/coins/audit   supply report + any wallet/transfer discrepancy (both lists empty = healthy)
func (a *API) adminAudit(w http.ResponseWriter, r *http.Request) {
	var report string
	if err := a.DB.QueryRow(r.Context(), `select coin_supply_report()::text`).Scan(&report); err != nil {
		dbErr(w, "adminAudit report", err)
		return
	}
	type walletIssue struct {
		UserID           int64  `json:"user_id"`
		Asset            string `json:"asset"`
		WalletBalance    int64  `json:"wallet_balance"`
		LedgerSum        int64  `json:"ledger_sum"`
		LastBalanceAfter int64  `json:"last_balance_after"`
	}
	wi := []walletIssue{}
	rows, err := a.DB.Query(r.Context(), `
		select user_id, asset::text, wallet_balance, ledger_sum, coalesce(last_balance_after,0)
		from audit_wallet_integrity() limit 100`)
	if err != nil {
		dbErr(w, "adminAudit wallets", err)
		return
	}
	for rows.Next() {
		var x walletIssue
		if err := rows.Scan(&x.UserID, &x.Asset, &x.WalletBalance, &x.LedgerSum, &x.LastBalanceAfter); err != nil {
			rows.Close()
			dbErr(w, "adminAudit wallets scan", err)
			return
		}
		wi = append(wi, x)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		dbErr(w, "adminAudit wallets rows", err)
		return
	}

	type transferIssue struct {
		TransferID int64  `json:"transfer_id"`
		Kind       string `json:"kind"`
		Amount     int64  `json:"amount"`
		Legs       int64  `json:"legs"`
		Net        int64  `json:"net"`
	}
	ti := []transferIssue{}
	rows, err = a.DB.Query(r.Context(), `select transfer_id, kind::text, amount, legs, net from audit_transfers() limit 100`)
	if err != nil {
		dbErr(w, "adminAudit transfers", err)
		return
	}
	for rows.Next() {
		var x transferIssue
		if err := rows.Scan(&x.TransferID, &x.Kind, &x.Amount, &x.Legs, &x.Net); err != nil {
			rows.Close()
			dbErr(w, "adminAudit transfers scan", err)
			return
		}
		ti = append(ti, x)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		dbErr(w, "adminAudit transfers rows", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"healthy":         len(wi) == 0 && len(ti) == 0,
		"supply":          json.RawMessage(report),
		"wallet_issues":   wi,
		"transfer_issues": ti,
	})
}

// nullable turns "" into SQL NULL.
func nullable(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}
