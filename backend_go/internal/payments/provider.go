// Package payments contains gateway adapters. The server decides the amount
// from recharge_packages; a gateway callback can only confirm what we asked for.
package payments

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
)

var (
	ErrBadSignature   = errors.New("invalid webhook signature")
	ErrIgnored        = errors.New("event ignored")
	ErrNotImplemented = errors.New("payment provider not available")
)

// Order is what we send to a gateway.
type Order struct {
	ID          string // recharge_orders.id (uuid)
	UserID      int64
	AmountMinor int64 // 500.00 BDT -> 50000
	Currency    string
	Coins       int64
}

type InitResult struct {
	PaymentURL        string // open in WebView / external browser
	ProviderPaymentID string // stored in recharge_orders.provider_payment_id
}

// Settlement is a verified gateway outcome for one order.
type Settlement struct {
	OrderID       string
	ProviderTrxID string
	EventID       string // unique per gateway event (dedupe key)
	AmountMinor   int64
	Currency      string
	Paid          bool
	Raw           []byte // JSON stored for audit
}

// Lookup resolves a gateway payment id to our order id.
type Lookup func(ctx context.Context, provider, providerPaymentID string) (orderID string, err error)

type Provider interface {
	Name() string     // matches DB enum pay_provider
	Currency() string // currency charged by this gateway
	Initiate(ctx context.Context, o Order) (InitResult, error)
	// HandleCallback verifies and parses a webhook / redirect callback.
	// Return ErrIgnored for events that need no action, ErrBadSignature for forgeries.
	HandleCallback(ctx context.Context, r *http.Request, lookup Lookup) (*Settlement, error)
}

// ParseMinor converts "500.00" / "12.5" / "7" to minor units without floats.
func ParseMinor(s string) (int64, error) {
	s = strings.TrimSpace(s)
	parts := strings.SplitN(s, ".", 2)
	whole, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil || whole < 0 {
		return 0, fmt.Errorf("bad amount %q", s)
	}
	var frac int64
	if len(parts) == 2 {
		f := parts[1]
		if len(f) > 2 {
			if strings.Trim(f[2:], "0") != "" {
				return 0, fmt.Errorf("bad amount precision %q", s)
			}
			f = f[:2]
		}
		for len(f) < 2 {
			f += "0"
		}
		if frac, err = strconv.ParseInt(f, 10, 64); err != nil {
			return 0, fmt.Errorf("bad amount %q", s)
		}
	}
	return whole*100 + frac, nil
}

func FormatMinor(m int64) string { return fmt.Sprintf("%d.%02d", m/100, m%100) }

// Unavailable is registered for gateways that are not wired up yet
// (Nagad, Rocket) so the API answers 501 instead of 400.
type Unavailable struct{ name, currency string }

func NewUnavailable(name, currency string) Unavailable { return Unavailable{name, currency} }

func (u Unavailable) Name() string     { return u.name }
func (u Unavailable) Currency() string { return u.currency }
func (u Unavailable) Initiate(context.Context, Order) (InitResult, error) {
	return InitResult{}, ErrNotImplemented
}
func (u Unavailable) HandleCallback(context.Context, *http.Request, Lookup) (*Settlement, error) {
	return nil, ErrIgnored
}
