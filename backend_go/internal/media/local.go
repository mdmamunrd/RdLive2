package media

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Local stores files under Root. Uploads go through the API (PUT /v1/media/{id}/content) and
// downloads through the authenticated GET /v1/media/{id}, so only chat participants can read them.
type Local struct {
	Root    string // directory, created on demand
	BaseURL string // public base of this API, e.g. https://api.example.com
}

func (l *Local) Kind() string { return "local" }

func (l *Local) UploadTarget(_ context.Context, mediaID, _, mime string, _ int64, _ time.Duration) (UploadTarget, error) {
	return UploadTarget{
		Method:  "PUT",
		URL:     strings.TrimRight(l.BaseURL, "/") + "/v1/media/" + mediaID + "/content",
		Headers: map[string]string{"Content-Type": mime, "Authorization": "Bearer <access token>"},
	}, nil
}

func (l *Local) DownloadURL(_ context.Context, mediaID, _ string, _ time.Duration) (string, error) {
	return strings.TrimRight(l.BaseURL, "/") + "/v1/media/" + mediaID, nil // needs the Authorization header
}

func (l *Local) path(key string) (string, error) {
	if !ValidKey(key) {
		return "", fmt.Errorf("media: invalid key %q", key)
	}
	root, err := filepath.Abs(l.Root) // also makes MEDIA_DIR=. work
	if err != nil {
		return "", err
	}
	p := filepath.Join(root, filepath.FromSlash(key))
	if !strings.HasPrefix(p, root+string(os.PathSeparator)) {
		return "", errors.New("media: path escapes root")
	}
	return p, nil
}

// Delete removes the file (idempotent).
func (l *Local) Delete(_ context.Context, key string) error {
	p, err := l.path(key)
	if err != nil {
		return err
	}
	if err := os.Remove(p); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

func (l *Local) Stat(_ context.Context, key string) (int64, error) {
	p, err := l.path(key)
	if err != nil {
		return 0, err
	}
	fi, err := os.Stat(p)
	if errors.Is(err, os.ErrNotExist) {
		return 0, ErrNotFound
	}
	if err != nil {
		return 0, err
	}
	return fi.Size(), nil
}

// ErrTooLarge / ErrBadContent are returned by Save.
var (
	ErrTooLarge   = errors.New("media: file too large")
	ErrBadContent = errors.New("media: file content does not match the declared type")
)

// Save streams r to disk (atomically, max bytes) after checking the real content type from the first
// bytes: a client cannot upload an .html / .svg / .exe and call it image/png.
func (l *Local) Save(key, mime string, r io.Reader, max int64) (int64, error) {
	p, err := l.path(key)
	if err != nil {
		return 0, err
	}
	head := make([]byte, 512)
	n, err := io.ReadFull(io.LimitReader(r, 512), head)
	if err != nil && !errors.Is(err, io.ErrUnexpectedEOF) && !errors.Is(err, io.EOF) {
		return 0, err
	}
	head = head[:n]
	if n == 0 || http.DetectContentType(head) != strings.ToLower(mime) {
		return 0, ErrBadContent
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o750); err != nil {
		return 0, err
	}
	tmp, err := os.CreateTemp(filepath.Dir(p), ".upload-*")
	if err != nil {
		return 0, err
	}
	defer os.Remove(tmp.Name()) // no-op after a successful rename
	total := int64(n)
	if total > max {
		_ = tmp.Close()
		return 0, ErrTooLarge
	}
	if _, err := tmp.Write(head); err != nil {
		_ = tmp.Close()
		return 0, err
	}
	rest, err := io.Copy(tmp, io.LimitReader(r, max-total+1))
	if err != nil {
		_ = tmp.Close()
		return 0, err
	}
	total += rest
	if total > max {
		_ = tmp.Close()
		return 0, ErrTooLarge
	}
	if err := tmp.Close(); err != nil {
		return 0, err
	}
	if err := os.Chmod(tmp.Name(), 0o640); err != nil {
		return 0, err
	}
	if err := os.Rename(tmp.Name(), p); err != nil {
		return 0, err
	}
	return total, nil
}

// Open returns the stored file for serving.
func (l *Local) Open(key string) (*os.File, error) {
	p, err := l.path(key)
	if err != nil {
		return nil, err
	}
	f, err := os.Open(p)
	if errors.Is(err, os.ErrNotExist) {
		return nil, ErrNotFound
	}
	return f, err
}
