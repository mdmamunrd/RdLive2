package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"rdlive/internal/api"
	"rdlive/internal/auth"
	"rdlive/internal/config"
	"rdlive/internal/media"
	"rdlive/internal/payments"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatal(err)
	}
	ctx := context.Background()

	pool, err := pgxpool.New(ctx, cfg.DatabaseURL)
	if err != nil {
		log.Fatalf("db: %v", err)
	}
	defer pool.Close()
	if err := pool.Ping(ctx); err != nil {
		log.Fatalf("db ping: %v", err)
	}

	providers := map[string]payments.Provider{
		// Nagad needs merchant RSA keys; Rocket is usually reached through an
		// aggregator. Until implemented they answer 501.
		"nagad":  payments.NewUnavailable("nagad", "BDT"),
		"rocket": payments.NewUnavailable("rocket", "BDT"),
	}
	if cfg.BKash.Enabled() {
		b := cfg.BKash
		providers["bkash"] = payments.NewBKash(b.BaseURL, b.AppKey, b.AppSecret, b.Username, b.Password, cfg.PublicBaseURL)
	} else {
		providers["bkash"] = payments.NewUnavailable("bkash", "BDT")
		log.Println("bKash not configured")
	}
	if cfg.Stripe.SecretKey != "" && cfg.Stripe.WebhookSecret != "" {
		providers["card"] = payments.NewStripe(cfg.Stripe.SecretKey, cfg.Stripe.WebhookSecret, cfg.PublicBaseURL)
	} else {
		providers["card"] = payments.NewUnavailable("card", "USD")
		log.Println("Stripe not configured")
	}

	// Chat images: an S3-compatible bucket in production, a local folder in development.
	var store media.Store
	if cfg.S3.Enabled() {
		s := cfg.S3
		store = &media.S3{Endpoint: s.Endpoint, Bucket: s.Bucket, Region: s.Region, AccessKey: s.AccessKey, SecretKey: s.SecretKey, PathStyle: s.PathStyle}
		log.Printf("chat images: S3-compatible bucket %q", s.Bucket)
	} else {
		store = &media.Local{Root: cfg.MediaDir, BaseURL: cfg.PublicBaseURL}
		log.Printf("chat images: local folder %q (set S3_* for production)", cfg.MediaDir)
	}

	// Background workers (realtime listener, chat loader, PK ticker) live as long as workerCtx.
	workerCtx, stopWorkers := context.WithCancel(context.Background())
	defer stopWorkers()
	server := api.NewServer(api.Deps{
		Cfg:       cfg,
		DB:        pool,
		Verifier:  auth.NewFirebaseVerifier(cfg.FirebaseProjectID),
		Tokens:    auth.NewTokens(cfg.JWTSecret, cfg.AccessTTL),
		Providers: providers,
		Media:     store,
	})
	server.Start(workerCtx)

	srv := &http.Server{
		Addr:              cfg.Addr,
		Handler:           server.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      35 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	go func() {
		log.Printf("rdlive api listening on %s", cfg.Addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
	stopWorkers()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdownCtx)
}
