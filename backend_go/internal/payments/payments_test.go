package payments

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestParseMinor(t *testing.T) {
	ok := map[string]int64{"500.00": 50000, "12.5": 1250, "7": 700, "0.01": 1, "100.000": 10000, " 3.20 ": 320}
	for in, want := range ok {
		got, err := ParseMinor(in)
		if err != nil || got != want {
			t.Errorf("ParseMinor(%q)=%d,%v want %d", in, got, err, want)
		}
	}
	for _, in := range []string{"", "abc", "-1.00", "1.234", "1.2x"} {
		if _, err := ParseMinor(in); err == nil {
			t.Errorf("ParseMinor(%q) should fail", in)
		}
	}
	if FormatMinor(50005) != "500.05" {
		t.Error("FormatMinor")
	}
}

func sign(secret string, ts int64, payload string) string {
	m := hmac.New(sha256.New, []byte(secret))
	m.Write([]byte(strconv.FormatInt(ts, 10) + "." + payload))
	return "t=" + strconv.FormatInt(ts, 10) + ",v1=" + hex.EncodeToString(m.Sum(nil))
}

func TestStripeSignature(t *testing.T) {
	now := time.Now()
	body := `{"id":"evt_1"}`
	good := sign("whsec_x", now.Unix(), body)
	if err := VerifyStripeSignature([]byte(body), good, "whsec_x", now, 5*time.Minute); err != nil {
		t.Fatalf("valid signature rejected: %v", err)
	}
	cases := map[string]string{
		"wrong secret": sign("other", now.Unix(), body),
		"stale":        sign("whsec_x", now.Add(-time.Hour).Unix(), body),
		"empty":        "",
		"garbage":      "t=abc,v1=zz",
	}
	for name, h := range cases {
		if err := VerifyStripeSignature([]byte(body), h, "whsec_x", now, 5*time.Minute); !errors.Is(err, ErrBadSignature) {
			t.Errorf("%s: want ErrBadSignature got %v", name, err)
		}
	}
	if err := VerifyStripeSignature([]byte(body+" "), good, "whsec_x", now, 5*time.Minute); err == nil {
		t.Error("tampered body accepted")
	}
}

func TestStripeHandleCallback(t *testing.T) {
	s := NewStripe("sk", "whsec_x", "https://api.test")
	call := func(body string) (*Settlement, error) {
		r := httptest.NewRequest(http.MethodPost, "/webhooks/card", strings.NewReader(body))
		r.Header.Set("Stripe-Signature", sign("whsec_x", time.Now().Unix(), body))
		return s.HandleCallback(context.Background(), r, nil)
	}

	paid := `{"id":"evt_1","type":"checkout.session.completed","data":{"object":{"client_reference_id":"ord-1","payment_status":"paid","amount_total":450,"currency":"usd","payment_intent":"pi_1"}}}`
	st, err := call(paid)
	if err != nil || !st.Paid || st.OrderID != "ord-1" || st.AmountMinor != 450 || st.Currency != "USD" || st.ProviderTrxID != "pi_1" || st.EventID != "evt_1" {
		t.Fatalf("paid event parsed wrong: %+v %v", st, err)
	}

	unpaid := strings.Replace(paid, `"paid"`, `"unpaid"`, 1)
	if _, err := call(unpaid); !errors.Is(err, ErrIgnored) {
		t.Errorf("unpaid completed session should be ignored, got %v", err)
	}
	other := strings.Replace(paid, "checkout.session.completed", "customer.created", 1)
	if _, err := call(other); !errors.Is(err, ErrIgnored) {
		t.Errorf("unrelated event should be ignored, got %v", err)
	}

	r := httptest.NewRequest(http.MethodPost, "/webhooks/card", strings.NewReader(paid))
	r.Header.Set("Stripe-Signature", sign("wrong", time.Now().Unix(), paid))
	if _, err := s.HandleCallback(context.Background(), r, nil); !errors.Is(err, ErrBadSignature) {
		t.Errorf("forged webhook accepted: %v", err)
	}
}

func TestBKashCallbackFlow(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/tokenized/checkout/token/grant", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("username") != "u" || r.Header.Get("password") != "p" {
			http.Error(w, "no", 401)
			return
		}
		_, _ = w.Write([]byte(`{"statusCode":"0000","id_token":"TOK","expires_in":3600}`))
	})
	mux.HandleFunc("/tokenized/checkout/execute", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "TOK" {
			http.Error(w, "no", 401)
			return
		}
		_, _ = w.Write([]byte(`{"statusCode":"0000","transactionStatus":"Completed","trxID":"TRX9","amount":"500.00","currency":"BDT","merchantInvoiceNumber":"ord-1","paymentID":"P1"}`))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	b := NewBKash(srv.URL, "k", "s", "u", "p", "https://api.test")
	lookup := func(_ context.Context, prov, pid string) (string, error) {
		if prov != "bkash" || pid != "P1" {
			return "", errors.New("not found")
		}
		return "ord-1", nil
	}

	r := httptest.NewRequest(http.MethodGet, "/webhooks/bkash?paymentID=P1&status=success", nil)
	st, err := b.HandleCallback(context.Background(), r, lookup)
	if err != nil || !st.Paid || st.AmountMinor != 50000 || st.Currency != "BDT" || st.ProviderTrxID != "TRX9" || st.OrderID != "ord-1" {
		t.Fatalf("bkash success parsed wrong: %+v %v", st, err)
	}

	r = httptest.NewRequest(http.MethodGet, "/webhooks/bkash?paymentID=P1&status=cancel", nil)
	st, err = b.HandleCallback(context.Background(), r, lookup)
	if err != nil || st.Paid {
		t.Fatalf("cancel should be unpaid: %+v %v", st, err)
	}

	r = httptest.NewRequest(http.MethodGet, "/webhooks/bkash", nil)
	if _, err := b.HandleCallback(context.Background(), r, lookup); !errors.Is(err, ErrIgnored) {
		t.Errorf("missing paymentID should be ignored: %v", err)
	}
}
