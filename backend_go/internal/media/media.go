// Package media keeps image BYTES out of the database. The database only stores a reference
// (media_assets.storage + storage_key); this package knows how to put/get the bytes:
//
//	Local  - files under MEDIA_DIR, uploaded through and served by the API itself (dev / single server)
//	S3     - any S3-compatible bucket (AWS S3, Cloudflare R2, DigitalOcean Spaces, MinIO) using
//	         presigned URLs, so image bytes never pass through the API (production)
package media

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"time"
)

// UploadTarget tells the client how to upload the bytes.
type UploadTarget struct {
	Method  string            `json:"method"`
	URL     string            `json:"url"`
	Headers map[string]string `json:"headers,omitempty"`
}

// Store is what the HTTP layer needs. Kind() is stored in media_assets.storage.
type Store interface {
	Kind() string
	// UploadTarget returns where/how the client uploads (mediaID is the media_assets.id).
	UploadTarget(ctx context.Context, mediaID, key, mime string, size int64, ttl time.Duration) (UploadTarget, error)
	// DownloadURL returns a URL the client can GET the image from.
	DownloadURL(ctx context.Context, mediaID, key string, ttl time.Duration) (string, error)
	// Stat returns the stored object's size; ErrNotFound if the upload never arrived.
	Stat(ctx context.Context, key string) (int64, error)
	// Delete removes the object. Deleting something that is already gone is NOT an error.
	Delete(ctx context.Context, key string) error
}

var ErrNotFound = errors.New("media: object not found")

// Allowed image types and their canonical extension.
var Types = map[string]string{
	"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp", "image/gif": ".gif",
}

var keyRe = regexp.MustCompile(`^chat/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp|gif)$`)

// ValidKey guards every filesystem/URL use of a storage key (no traversal, no surprises).
func ValidKey(k string) bool { return keyRe.MatchString(k) }

// ValidMime reports whether mime is an accepted image type.
func ValidMime(m string) bool { _, ok := Types[strings.ToLower(m)]; return ok }
