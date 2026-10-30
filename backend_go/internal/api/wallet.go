package api

import (
	"net/http"
	"strconv"
	"time"
)

// GET /v1/wallet
func (a *API) wallet(w http.ResponseWriter, r *http.Request) {
	var coins, diamonds int64
	err := a.DB.QueryRow(r.Context(), `select coins,diamonds from wallets where user_id=$1`, userID(r.Context())).Scan(&coins, &diamonds)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "try again")
		return
	}
	var rate float64
	_ = a.DB.QueryRow(r.Context(), `
		select diamonds_per_bdt::float8 from exchange_rates
		where effective_from<=now() order by effective_from desc limit 1`).Scan(&rate)
	writeJSON(w, http.StatusOK, map[string]any{"coins": coins, "diamonds": diamonds, "diamonds_per_bdt": rate})
}

// GET /v1/wallet/ledger?before_id=&limit=   (passbook / transaction history)
func (a *API) ledger(w http.ResponseWriter, r *http.Request) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 || limit > 100 {
		limit = 30
	}
	before, _ := strconv.ParseInt(r.URL.Query().Get("before_id"), 10, 64)

	rows, err := a.DB.Query(r.Context(), `
		select id, asset::text, amount, balance_after, tx_type::text, coalesce(ref_type,''), created_at
		from wallet_ledger
		where user_id=$1 and ($2::bigint=0 or id<$2::bigint)
		order by id desc limit $3`, userID(r.Context()), before, limit)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "try again")
		return
	}
	defer rows.Close()
	type item struct {
		ID           int64     `json:"id"`
		Asset        string    `json:"asset"`
		Amount       int64     `json:"amount"`
		BalanceAfter int64     `json:"balance_after"`
		Type         string    `json:"type"`
		RefType      string    `json:"ref_type,omitempty"`
		CreatedAt    time.Time `json:"created_at"`
	}
	items := []item{}
	for rows.Next() {
		var it item
		if err := rows.Scan(&it.ID, &it.Asset, &it.Amount, &it.BalanceAfter, &it.Type, &it.RefType, &it.CreatedAt); err != nil {
			writeErr(w, http.StatusInternalServerError, "internal", "try again")
			return
		}
		items = append(items, it)
	}
	var next int64
	if len(items) == limit {
		next = items[len(items)-1].ID
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "next_before_id": next})
}
