package payments

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sync"
	"time"
)

// BKash implements bKash Tokenized Checkout (create -> user pays on bKash ->
// callback with paymentID -> server-side execute). Check field names against
// the bKash docs/sandbox version you were issued; the flow is stable but
// merchants are sometimes on different API versions.
type BKash struct {
	baseURL, appKey, appSecret, username, password string
	callbackURL                                    string
	hc                                             *http.Client

	mu    sync.Mutex
	token string
	exp   time.Time
}

func NewBKash(baseURL, appKey, appSecret, username, password, publicBaseURL string) *BKash {
	return &BKash{
		baseURL: baseURL, appKey: appKey, appSecret: appSecret, username: username, password: password,
		callbackURL: publicBaseURL + "/webhooks/bkash",
		hc:          &http.Client{Timeout: 20 * time.Second},
	}
}

func (b *BKash) Name() string     { return "bkash" }
func (b *BKash) Currency() string { return "BDT" }

func (b *BKash) grant(ctx context.Context) (string, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.token != "" && time.Now().Before(b.exp) {
		return b.token, nil
	}
	body, _ := json.Marshal(map[string]string{"app_key": b.appKey, "app_secret": b.appSecret})
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, b.baseURL+"/tokenized/checkout/token/grant", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("username", b.username)
	req.Header.Set("password", b.password)
	res, err := b.hc.Do(req)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	var out struct {
		IDToken   string `json:"id_token"`
		ExpiresIn int    `json:"expires_in"`
		Status    string `json:"statusCode"`
	}
	if err := json.Unmarshal(raw, &out); err != nil || out.IDToken == "" || (out.Status != "" && out.Status != "0000") {
		return "", errors.New("bkash: token grant failed")
	}
	if out.ExpiresIn < 120 {
		out.ExpiresIn = 120
	}
	b.token = out.IDToken
	b.exp = time.Now().Add(time.Duration(out.ExpiresIn-60) * time.Second)
	return b.token, nil
}

func (b *BKash) call(ctx context.Context, path string, in, out any) error {
	tok, err := b.grant(ctx)
	if err != nil {
		return err
	}
	body, _ := json.Marshal(in)
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, b.baseURL+path, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", tok)
	req.Header.Set("X-APP-Key", b.appKey)
	res, err := b.hc.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if res.StatusCode/100 != 2 {
		return fmt.Errorf("bkash %s: status %d", path, res.StatusCode)
	}
	return json.Unmarshal(raw, out)
}

func (b *BKash) Initiate(ctx context.Context, o Order) (InitResult, error) {
	var out struct {
		PaymentID string `json:"paymentID"`
		BkashURL  string `json:"bkashURL"`
		Status    string `json:"statusCode"`
		Message   string `json:"statusMessage"`
	}
	err := b.call(ctx, "/tokenized/checkout/create", map[string]string{
		"mode":                  "0011",
		"payerReference":        fmt.Sprintf("%d", o.UserID),
		"callbackURL":           b.callbackURL,
		"amount":                FormatMinor(o.AmountMinor),
		"currency":              "BDT",
		"intent":                "sale",
		"merchantInvoiceNumber": o.ID,
	}, &out)
	if err != nil {
		return InitResult{}, err
	}
	if out.Status != "0000" || out.PaymentID == "" || out.BkashURL == "" {
		return InitResult{}, fmt.Errorf("bkash create failed: %s %s", out.Status, out.Message)
	}
	return InitResult{PaymentURL: out.BkashURL, ProviderPaymentID: out.PaymentID}, nil
}

type bkashResult struct {
	Status    string `json:"statusCode"`
	TxStatus  string `json:"transactionStatus"`
	TrxID     string `json:"trxID"`
	Amount    string `json:"amount"`
	Currency  string `json:"currency"`
	InvoiceNo string `json:"merchantInvoiceNumber"`
	PaymentID string `json:"paymentID"`
	StatusMsg string `json:"statusMessage"`
}

// execute finalises the payment. If execute was already called (user reloaded
// the callback) it falls back to a status query, which is idempotent.
func (b *BKash) execute(ctx context.Context, paymentID string) (*bkashResult, []byte, error) {
	var res bkashResult
	err := b.call(ctx, "/tokenized/checkout/execute", map[string]string{"paymentID": paymentID}, &res)
	if err != nil || res.Status != "0000" || res.TrxID == "" {
		var q bkashResult
		if qerr := b.call(ctx, "/tokenized/checkout/payment/status", map[string]string{"paymentID": paymentID}, &q); qerr != nil {
			if err == nil {
				err = qerr
			}
			return nil, nil, err
		}
		res = q
	}
	raw, _ := json.Marshal(res)
	return &res, raw, nil
}

func (b *BKash) HandleCallback(ctx context.Context, r *http.Request, lookup Lookup) (*Settlement, error) {
	pid := r.URL.Query().Get("paymentID")
	status := r.URL.Query().Get("status")
	if pid == "" {
		return nil, ErrIgnored
	}
	orderID, err := lookup(ctx, "bkash", pid)
	if err != nil {
		return nil, err
	}
	if status != "success" {
		return &Settlement{OrderID: orderID, EventID: "bkash:" + pid + ":" + status, Paid: false}, nil
	}
	res, raw, err := b.execute(ctx, pid)
	if err != nil {
		return nil, err
	}
	if res.InvoiceNo != orderID {
		return nil, fmt.Errorf("bkash: invoice mismatch")
	}
	if res.Status != "0000" || res.TxStatus != "Completed" || res.TrxID == "" {
		return &Settlement{OrderID: orderID, EventID: "bkash:" + pid + ":failed", Paid: false, Raw: raw}, nil
	}
	minor, err := ParseMinor(res.Amount)
	if err != nil {
		return nil, err
	}
	return &Settlement{
		OrderID: orderID, ProviderTrxID: res.TrxID, EventID: "bkash:" + pid + ":" + res.TrxID,
		AmountMinor: minor, Currency: res.Currency, Paid: true, Raw: raw,
	}, nil
}
