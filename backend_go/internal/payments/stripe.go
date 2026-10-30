package payments

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// Stripe implements card payments through Stripe Checkout.
type Stripe struct {
	secretKey, webhookSecret, publicBaseURL string
	hc                                      *http.Client
	apiBase                                 string
}

func NewStripe(secretKey, webhookSecret, publicBaseURL string) *Stripe {
	return &Stripe{
		secretKey: secretKey, webhookSecret: webhookSecret, publicBaseURL: publicBaseURL,
		hc: &http.Client{Timeout: 15 * time.Second}, apiBase: "https://api.stripe.com",
	}
}

func (s *Stripe) Name() string     { return "card" }
func (s *Stripe) Currency() string { return "USD" }

func (s *Stripe) Initiate(ctx context.Context, o Order) (InitResult, error) {
	form := url.Values{}
	form.Set("mode", "payment")
	form.Set("client_reference_id", o.ID)
	form.Set("metadata[order_id]", o.ID)
	form.Set("success_url", s.publicBaseURL+"/pay/return?status=success&order="+o.ID)
	form.Set("cancel_url", s.publicBaseURL+"/pay/return?status=cancel&order="+o.ID)
	form.Set("line_items[0][quantity]", "1")
	form.Set("line_items[0][price_data][currency]", strings.ToLower(o.Currency))
	form.Set("line_items[0][price_data][unit_amount]", strconv.FormatInt(o.AmountMinor, 10))
	form.Set("line_items[0][price_data][product_data][name]", fmt.Sprintf("rdlive coins x%d", o.Coins))

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.apiBase+"/v1/checkout/sessions", strings.NewReader(form.Encode()))
	if err != nil {
		return InitResult{}, err
	}
	req.SetBasicAuth(s.secretKey, "")
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Idempotency-Key", "rdlive-order-"+o.ID)
	res, err := s.hc.Do(req)
	if err != nil {
		return InitResult{}, err
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if res.StatusCode/100 != 2 {
		return InitResult{}, fmt.Errorf("stripe: status %d", res.StatusCode)
	}
	var out struct {
		ID  string `json:"id"`
		URL string `json:"url"`
	}
	if err := json.Unmarshal(body, &out); err != nil || out.URL == "" {
		return InitResult{}, fmt.Errorf("stripe: bad response")
	}
	return InitResult{PaymentURL: out.URL, ProviderPaymentID: out.ID}, nil
}

type stripeEvent struct {
	ID   string `json:"id"`
	Type string `json:"type"`
	Data struct {
		Object struct {
			ClientReferenceID string `json:"client_reference_id"`
			PaymentStatus     string `json:"payment_status"`
			AmountTotal       int64  `json:"amount_total"`
			Currency          string `json:"currency"`
			PaymentIntent     string `json:"payment_intent"`
		} `json:"object"`
	} `json:"data"`
}

func (s *Stripe) HandleCallback(_ context.Context, r *http.Request, _ Lookup) (*Settlement, error) {
	if r.Method != http.MethodPost {
		return nil, ErrIgnored
	}
	payload, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	if err := VerifyStripeSignature(payload, r.Header.Get("Stripe-Signature"), s.webhookSecret, time.Now(), 5*time.Minute); err != nil {
		return nil, ErrBadSignature
	}
	var ev stripeEvent
	if err := json.Unmarshal(payload, &ev); err != nil {
		return nil, err
	}
	obj := ev.Data.Object
	st := &Settlement{
		OrderID: obj.ClientReferenceID, ProviderTrxID: obj.PaymentIntent, EventID: ev.ID,
		AmountMinor: obj.AmountTotal, Currency: strings.ToUpper(obj.Currency), Raw: payload,
	}
	switch ev.Type {
	case "checkout.session.completed", "checkout.session.async_payment_succeeded":
		if obj.PaymentStatus != "paid" {
			return nil, ErrIgnored // async method still pending
		}
		st.Paid = true
	case "checkout.session.async_payment_failed", "checkout.session.expired":
		st.Paid = false
	default:
		return nil, ErrIgnored
	}
	if st.OrderID == "" {
		return nil, ErrIgnored
	}
	return st, nil
}

// VerifyStripeSignature checks the "Stripe-Signature: t=...,v1=..." header.
func VerifyStripeSignature(payload []byte, header, secret string, now time.Time, tolerance time.Duration) error {
	if secret == "" || header == "" {
		return ErrBadSignature
	}
	var ts string
	var sigs []string
	for _, part := range strings.Split(header, ",") {
		k, v, ok := strings.Cut(strings.TrimSpace(part), "=")
		if !ok {
			continue
		}
		switch k {
		case "t":
			ts = v
		case "v1":
			sigs = append(sigs, v)
		}
	}
	t, err := strconv.ParseInt(ts, 10, 64)
	if err != nil || len(sigs) == 0 {
		return ErrBadSignature
	}
	if d := now.Sub(time.Unix(t, 0)); d > tolerance || d < -tolerance {
		return ErrBadSignature
	}
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(ts + "."))
	mac.Write(payload)
	want := mac.Sum(nil)
	for _, s := range sigs {
		got, err := hex.DecodeString(s)
		if err == nil && hmac.Equal(got, want) {
			return nil
		}
	}
	return ErrBadSignature
}
