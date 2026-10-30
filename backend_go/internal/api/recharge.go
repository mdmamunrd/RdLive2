package api

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"net/url"
	"strings"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"rdlive/internal/payments"
)

// GET /v1/recharge/packages
func (a *API) packages(w http.ResponseWriter, r *http.Request) {
	rows, err := a.DB.Query(r.Context(), `
		select id, coins, bonus_coins, price_bdt::float8, price_usd::float8
		from recharge_packages where is_active order by sort_order, id`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "try again")
		return
	}
	defer rows.Close()
	type pkg struct {
		ID         int      `json:"id"`
		Coins      int64    `json:"coins"`
		BonusCoins int64    `json:"bonus_coins"`
		PriceBDT   float64  `json:"price_bdt"`
		PriceUSD   *float64 `json:"price_usd,omitempty"`
	}
	out := []pkg{}
	for rows.Next() {
		var p pkg
		if err := rows.Scan(&p.ID, &p.Coins, &p.BonusCoins, &p.PriceBDT, &p.PriceUSD); err != nil {
			writeErr(w, http.StatusInternalServerError, "internal", "try again")
			return
		}
		out = append(out, p)
	}
	methods := []string{}
	for name := range a.Providers {
		methods = append(methods, name)
	}
	writeJSON(w, http.StatusOK, map[string]any{"packages": out, "providers": methods})
}

// POST /v1/recharge/orders  {package_id, provider}
// The amount and coins come from the DB package, never from the client.
func (a *API) createOrder(w http.ResponseWriter, r *http.Request) {
	var req struct {
		PackageID int    `json:"package_id"`
		Provider  string `json:"provider"`
	}
	if !decode(w, r, &req) {
		return
	}
	prov, ok := a.Providers[req.Provider]
	if !ok {
		writeErr(w, http.StatusBadRequest, "unsupported_provider", "unknown payment provider")
		return
	}
	ctx := r.Context()
	uid := userID(ctx)

	var coins, bdtMinor int64
	var usdMinor *int64
	err := a.DB.QueryRow(ctx, `
		select coins+bonus_coins, (price_bdt*100)::bigint, (price_usd*100)::bigint
		from recharge_packages where id=$1 and is_active`, req.PackageID).Scan(&coins, &bdtMinor, &usdMinor)
	if errors.Is(err, pgx.ErrNoRows) {
		writeErr(w, http.StatusNotFound, "package_not_found", "package not available")
		return
	} else if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "try again")
		return
	}
	amount := bdtMinor
	if prov.Currency() == "USD" {
		if usdMinor == nil {
			writeErr(w, http.StatusBadRequest, "unsupported_provider", "package has no USD price")
			return
		}
		amount = *usdMinor
	}

	var pending int
	_ = a.DB.QueryRow(ctx, `
		select count(*) from recharge_orders
		where user_id=$1 and status in ('created','pending') and created_at>now()-interval '1 hour'`, uid).Scan(&pending)
	if pending >= 5 {
		writeErr(w, http.StatusTooManyRequests, "too_many_pending", "finish or cancel pending payments first")
		return
	}

	var orderID string
	err = a.DB.QueryRow(ctx, `
		insert into recharge_orders(user_id,package_id,provider,amount,currency,coins_granted,status)
		values($1,$2,$3::pay_provider,($4::bigint)/100.0,$5,$6,'created') returning id::text`,
		uid, req.PackageID, req.Provider, amount, prov.Currency(), coins).Scan(&orderID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "try again")
		return
	}

	res, err := prov.Initiate(ctx, payments.Order{ID: orderID, UserID: uid, AmountMinor: amount, Currency: prov.Currency(), Coins: coins})
	if err != nil {
		_, _ = a.DB.Exec(context.WithoutCancel(ctx), `update recharge_orders set status='failed' where id=$1::uuid`, orderID)
		if errors.Is(err, payments.ErrNotImplemented) {
			writeErr(w, http.StatusNotImplemented, "provider_unavailable", req.Provider+" is not available yet")
			return
		}
		log.Printf("initiate %s order=%s: %v", req.Provider, orderID, err)
		writeErr(w, http.StatusBadGateway, "gateway_error", "payment gateway error, try again")
		return
	}
	_, _ = a.DB.Exec(ctx, `update recharge_orders set status='pending', provider_payment_id=$2 where id=$1::uuid`, orderID, res.ProviderPaymentID)
	writeJSON(w, http.StatusCreated, map[string]any{
		"order_id": orderID, "payment_url": res.PaymentURL, "coins": coins, "amount_minor": amount, "currency": prov.Currency(),
	})
}

// GET /v1/recharge/orders/{id}  (app polls this after returning from the gateway)
func (a *API) getOrder(w http.ResponseWriter, r *http.Request) {
	var status, provider, currency string
	var coins, amount int64
	err := a.DB.QueryRow(r.Context(), `
		select status::text, provider::text, currency, coins_granted, (amount*100)::bigint
		from recharge_orders where id=$1::uuid and user_id=$2`, chi.URLParam(r, "id"), userID(r.Context())).
		Scan(&status, &provider, &currency, &coins, &amount)
	var pe *pgconn.PgError
	if errors.Is(err, pgx.ErrNoRows) || (errors.As(err, &pe) && pe.Code == "22P02") {
		writeErr(w, http.StatusNotFound, "not_found", "order not found")
		return
	} else if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "try again")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"order_id": chi.URLParam(r, "id"), "status": status, "provider": provider,
		"coins": coins, "amount_minor": amount, "currency": currency,
	})
}

// ---------------------------------------------------------------------
// Webhooks / gateway callbacks
// ---------------------------------------------------------------------

// ANY /webhooks/{provider}
func (a *API) paymentWebhook(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "method_not_allowed", "GET or POST only")
		return
	}
	name := chi.URLParam(r, "provider")
	prov, ok := a.Providers[name]
	if !ok {
		writeErr(w, http.StatusNotFound, "not_found", "unknown provider")
		return
	}
	ctx := r.Context()
	isRedirect := r.Method == http.MethodGet // browser redirect (bKash) vs server-to-server (Stripe)

	s, err := prov.HandleCallback(ctx, r, a.lookupOrderByPaymentID)
	switch {
	case errors.Is(err, payments.ErrIgnored):
		a.callbackReply(w, r, isRedirect, "", "ignored")
		return
	case errors.Is(err, payments.ErrBadSignature):
		log.Printf("webhook %s: bad signature from %s", name, clientIP(r))
		_, _ = a.DB.Exec(ctx, `
			insert into payment_webhook_events(provider,signature_ok,payload,error)
			values($1::pay_provider,false,jsonb_build_object('ip',$2::text),'bad signature')`, name, clientIP(r))
		writeErr(w, http.StatusBadRequest, "bad_signature", "invalid signature")
		return
	case err != nil:
		log.Printf("webhook %s: %v", name, err)
		if isRedirect {
			a.callbackReply(w, r, true, "", "error") // order stays pending; reconcile job can re-query
		} else {
			writeErr(w, http.StatusBadGateway, "gateway_error", "could not process callback")
		}
		return
	}

	status, err := a.applySettlement(ctx, name, s)
	if err != nil {
		log.Printf("settle %s order=%s: %v", name, s.OrderID, err)
		if isRedirect {
			a.callbackReply(w, r, true, s.OrderID, "error")
		} else {
			writeErr(w, http.StatusInternalServerError, "internal", "retry later") // gateway will retry
		}
		return
	}
	a.callbackReply(w, r, isRedirect, s.OrderID, status)
}

func (a *API) callbackReply(w http.ResponseWriter, r *http.Request, redirect bool, orderID, status string) {
	if redirect {
		q := url.Values{"order": {orderID}, "status": {status}}
		http.Redirect(w, r, a.Cfg.AppReturnURL+"?"+q.Encode(), http.StatusFound)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "status": status})
}

// GET /pay/return?...  Stripe success/cancel pages land here; we bounce into the app.
// Reaching this URL is NOT proof of payment: the app must poll the order.
func (a *API) payReturn(w http.ResponseWriter, r *http.Request) {
	q := url.Values{"order": {r.URL.Query().Get("order")}, "status": {r.URL.Query().Get("status")}}
	http.Redirect(w, r, a.Cfg.AppReturnURL+"?"+q.Encode(), http.StatusFound)
}

func (a *API) lookupOrderByPaymentID(ctx context.Context, provider, paymentID string) (string, error) {
	var id string
	err := a.DB.QueryRow(ctx, `
		select id::text from recharge_orders where provider=$1::pay_provider and provider_payment_id=$2`,
		provider, paymentID).Scan(&id)
	return id, err
}

// applySettlement records the event and, when the gateway confirms exactly what
// we asked for, calls settle_recharge(). Safe to run any number of times.
func (a *API) applySettlement(ctx context.Context, provider string, s *payments.Settlement) (string, error) {
	status := "failed"
	err := pgx.BeginFunc(ctx, a.DB, func(tx pgx.Tx) error {
		payload := s.Raw
		if len(payload) == 0 || !json.Valid(payload) {
			payload = []byte(`{}`)
		}
		var evID int64
		if err := tx.QueryRow(ctx, `
			insert into payment_webhook_events(provider,event_id,signature_ok,payload)
			values($1::pay_provider,$2,true,$3::jsonb)
			on conflict (provider,event_id) do update set received_at=payment_webhook_events.received_at
			returning id`, provider, s.EventID, string(payload)).Scan(&evID); err != nil {
			return err
		}
		finish := func(errMsg string) error {
			_, err := tx.Exec(ctx, `update payment_webhook_events set processed_at=now(), error=nullif($2,'') where id=$1`, evID, errMsg)
			return err
		}

		var oProv, oCur, oStatus string
		var oAmount int64
		err := tx.QueryRow(ctx, `
			select provider::text, currency, status::text, (amount*100)::bigint
			from recharge_orders where id=$1::uuid for update`, s.OrderID).Scan(&oProv, &oCur, &oStatus, &oAmount)
		if errors.Is(err, pgx.ErrNoRows) {
			status = "unknown_order"
			return finish("unknown order")
		}
		if err != nil {
			return err
		}
		if oProv != provider {
			status = "mismatch"
			return finish("provider mismatch")
		}

		if !s.Paid {
			if oStatus == "created" || oStatus == "pending" {
				if _, err := tx.Exec(ctx, `update recharge_orders set status='failed' where id=$1::uuid`, s.OrderID); err != nil {
					return err
				}
			} else if oStatus == "paid" {
				status = "paid" // never downgrade a paid order
			}
			return finish("")
		}

		if s.AmountMinor != oAmount || !strings.EqualFold(s.Currency, oCur) {
			log.Printf("ALERT amount mismatch order=%s expected=%d%s got=%d%s", s.OrderID, oAmount, oCur, s.AmountMinor, s.Currency)
			status = "mismatch"
			return finish("amount/currency mismatch")
		}
		if _, err := tx.Exec(ctx, `select settle_recharge($1::uuid,$2)`, s.OrderID, s.ProviderTrxID); err != nil {
			return err
		}
		status = "paid"
		return finish("")
	})
	return status, err
}
