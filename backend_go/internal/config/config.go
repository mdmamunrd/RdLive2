package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

type BKash struct {
	BaseURL   string // sandbox: https://tokenized.sandbox.bka.sh/v1.2.0-beta
	AppKey    string
	AppSecret string
	Username  string
	Password  string
}

func (b BKash) Enabled() bool {
	return b.BaseURL != "" && b.AppKey != "" && b.AppSecret != "" && b.Username != "" && b.Password != ""
}

type Stripe struct {
	SecretKey     string
	WebhookSecret string
}

// S3 is an S3-compatible bucket for chat images (AWS S3, Cloudflare R2, DigitalOcean Spaces, MinIO).
type S3 struct {
	Endpoint  string
	Bucket    string
	Region    string
	AccessKey string
	SecretKey string
	PathStyle bool
}

func (s S3) Enabled() bool {
	return s.Endpoint != "" && s.Bucket != "" && s.AccessKey != "" && s.SecretKey != ""
}

type Config struct {
	Addr              string
	DatabaseURL       string
	JWTSecret         string
	AccessTTL         time.Duration
	RefreshTTL        time.Duration
	FirebaseProjectID string
	PublicBaseURL     string // public https URL of this API (gateway callbacks)
	AppReturnURL      string // deep link the app handles, e.g. rdlive://payment
	RequireDeviceID   bool
	PortalOrigins     []string // browser origins allowed to call the admin/seller portal APIs
	BKash             BKash
	Stripe            Stripe
	S3                S3
	MediaDir          string        // local image storage when S3 is not configured
	MediaMaxBytes     int64         // largest accepted chat image
	PKTick            time.Duration // PK finisher interval (clamped to 2-5s)
}

func Load() (Config, error) {
	c := Config{
		Addr:              env("ADDR", ":8080"),
		DatabaseURL:       os.Getenv("DATABASE_URL"),
		JWTSecret:         os.Getenv("JWT_SECRET"),
		AccessTTL:         15 * time.Minute,
		RefreshTTL:        30 * 24 * time.Hour,
		FirebaseProjectID: os.Getenv("FIREBASE_PROJECT_ID"),
		PublicBaseURL:     strings.TrimRight(os.Getenv("PUBLIC_BASE_URL"), "/"),
		AppReturnURL:      env("APP_RETURN_URL", "rdlive://payment"),
		RequireDeviceID:   os.Getenv("REQUIRE_DEVICE_ID") == "true",
		PortalOrigins:     splitList(os.Getenv("PORTAL_ORIGINS")),
		BKash: BKash{
			BaseURL:   strings.TrimRight(os.Getenv("BKASH_BASE_URL"), "/"),
			AppKey:    os.Getenv("BKASH_APP_KEY"),
			AppSecret: os.Getenv("BKASH_APP_SECRET"),
			Username:  os.Getenv("BKASH_USERNAME"),
			Password:  os.Getenv("BKASH_PASSWORD"),
		},
		Stripe: Stripe{
			SecretKey:     os.Getenv("STRIPE_SECRET_KEY"),
			WebhookSecret: os.Getenv("STRIPE_WEBHOOK_SECRET"),
		},
		S3: S3{
			Endpoint:  strings.TrimRight(os.Getenv("S3_ENDPOINT"), "/"),
			Bucket:    os.Getenv("S3_BUCKET"),
			Region:    env("S3_REGION", "auto"),
			AccessKey: os.Getenv("S3_ACCESS_KEY"),
			SecretKey: os.Getenv("S3_SECRET_KEY"),
			PathStyle: os.Getenv("S3_PATH_STYLE") == "true",
		},
		MediaDir:      env("MEDIA_DIR", "./media_data"),
		MediaMaxBytes: envInt("MEDIA_MAX_BYTES", 5<<20),
		PKTick:        time.Duration(envInt("PK_TICK_SECONDS", 3)) * time.Second,
	}
	var missing []string
	if c.DatabaseURL == "" {
		missing = append(missing, "DATABASE_URL")
	}
	if len(c.JWTSecret) < 32 {
		missing = append(missing, "JWT_SECRET (min 32 chars)")
	}
	if c.FirebaseProjectID == "" {
		missing = append(missing, "FIREBASE_PROJECT_ID")
	}
	if c.PublicBaseURL == "" {
		missing = append(missing, "PUBLIC_BASE_URL")
	}
	if len(missing) > 0 {
		return c, fmt.Errorf("missing/invalid env: %s", strings.Join(missing, ", "))
	}
	return c, nil
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// splitList parses a comma separated env value, dropping blanks and trailing slashes.
func splitList(v string) []string {
	var out []string
	for _, p := range strings.Split(v, ",") {
		if p = strings.TrimRight(strings.TrimSpace(p), "/"); p != "" {
			out = append(out, p)
		}
	}
	return out
}

func envInt(k string, def int64) int64 {
	if v := os.Getenv(k); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil && n > 0 {
			return n
		}
	}
	return def
}
