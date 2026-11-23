// Package main deploys the RdLive API as a single Netlify Go function
// (Lambda compatibility mode). Every /v1/* request is rewritten to this
// function and forwarded to the same chi router the standalone server uses.
package main

import (
	"context"
	"log"
	"net/http"
	"strings"
	"sync"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/awslabs/aws-lambda-go-api-proxy/httpadapter"
	"github.com/jackc/pgx/v5/pgxpool"

	"rdlive/internal/api"
	"rdlive/internal/auth"
	"rdlive/internal/config"
	"rdlive/internal/media"
	"rdlive/internal/payments"
)

const fnPrefix = "/.netlify/functions/api"

var (
	startOnce sync.Once
	compiled  http.Handler
	startErr  error
)

func build() {
	cfg, err := config.Load()
	if err != nil {
		startErr = err
		return
	}
	pool, err := pgxpool.New(context.Background(), cfg.DatabaseURL)
	if err != nil {
		startErr = err
		return
	}
	if err := pool.Ping(context.Background()); err != nil {
		startErr = err
		return
	}
	providers := map[string]payments.Provider{
		"nagad":  payments.NewUnavailable("nagad", "BDT"),
		"rocket": payments.NewUnavailable("rocket", "BDT"),
	}
	if cfg.BKash.Enabled() {
		b := cfg.BKash
		providers["bkash"] = payments.NewBKash(b.BaseURL, b.AppKey, b.AppSecret, b.Username, b.Password, cfg.PublicBaseURL)
	} else {
		providers["bkash"] = payments.NewUnavailable("bkash", "BDT")
	}
	if cfg.Stripe.SecretKey != "" && cfg.Stripe.WebhookSecret != "" {
		providers["card"] = payments.NewStripe(cfg.Stripe.SecretKey, cfg.Stripe.WebhookSecret, cfg.PublicBaseURL)
	} else {
		providers["card"] = payments.NewUnavailable("card", "USD")
	}
	var store media.Store
	if cfg.S3.Enabled() {
		s := cfg.S3
		store = &media.S3{Endpoint: s.Endpoint, Bucket: s.Bucket, Region: s.Region, AccessKey: s.AccessKey, SecretKey: s.SecretKey, PathStyle: s.PathStyle}
	} else {
		store = &media.Local{Root: cfg.MediaDir, BaseURL: cfg.PublicBaseURL}
	}
	compiled = api.New(api.Deps{
		Cfg:       cfg,
		DB:        pool,
		Verifier:  auth.NewFirebaseVerifier(cfg.FirebaseProjectID),
		Tokens:    auth.NewTokens(cfg.JWTSecret, cfg.AccessTTL),
		Providers: providers,
		Media:     store,
	})
	log.Printf("rdlive netlify function ready (pool ok)")
}

func handler(ctx context.Context, req events.APIGatewayProxyRequest) (events.APIGatewayProxyResponse, error) {
	startOnce.Do(build)
	if startErr != nil {
		log.Printf("startup failed: %v", startErr)
		return events.APIGatewayProxyResponse{
			StatusCode: 500,
			Headers:    map[string]string{"Content-Type": "application/json"},
			Body:       `{"code":"startup_failed","message":"backend not configured (check DATABASE_URL / JWT_SECRET / FIREBASE_PROJECT_ID)"}`,
		}, nil
	}
	if p := req.Path; !strings.HasPrefix(p, "/v1") && !strings.HasPrefix(p, "/healthz") {
		req.Path = strings.TrimPrefix(p, fnPrefix)
	}
	return httpadapter.New(compiled).ProxyWithContext(ctx, req)
}

func main() {
	lambda.Start(handler)
}
