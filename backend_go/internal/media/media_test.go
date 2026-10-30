package media

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The official example from the AWS S3 documentation, "Authenticating Requests: Using Query
// Parameters (AWS Signature Version 4)": GET /test.txt on examplebucket, 2013-05-24, 86400 s.
func TestPresignMatchesAWSDocumentationVector(t *testing.T) {
	s := &S3{
		Endpoint: "https://s3.amazonaws.com", Bucket: "examplebucket", Region: "us-east-1",
		AccessKey: "AKIAIOSFODNN7EXAMPLE", SecretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
		Now: func() time.Time { return time.Date(2013, 5, 24, 0, 0, 0, 0, time.UTC) },
	}
	got, err := s.Presign("GET", "test.txt", 86400*time.Second, nil)
	if err != nil {
		t.Fatal(err)
	}
	want := "https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256" +
		"&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request" +
		"&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host" +
		"&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
	if got != want {
		t.Fatalf("presigned URL differs from the AWS reference:\n got  %s\n want %s", got, want)
	}
}

func TestPresignPathStyleAndSignedHeader(t *testing.T) {
	s := &S3{Endpoint: "https://acct.r2.cloudflarestorage.com", Bucket: "rd", Region: "auto", AccessKey: "AK", SecretKey: "SK", PathStyle: true,
		Now: func() time.Time { return time.Date(2026, 10, 25, 12, 0, 0, 0, time.UTC) }}
	u, err := s.Presign("PUT", "chat/11111111-2222-3333-4444-555555555555.png", 15*time.Minute, map[string]string{"Content-Type": "image/png"})
	if err != nil {
		t.Fatal(err)
	}
	for _, part := range []string{"https://acct.r2.cloudflarestorage.com/rd/chat/11111111-2222-3333-4444-555555555555.png?",
		"X-Amz-SignedHeaders=content-type%3Bhost", "X-Amz-Expires=900", "X-Amz-Signature="} {
		if !strings.Contains(u, part) {
			t.Errorf("missing %q in %s", part, u)
		}
	}
	u2, _ := s.Presign("PUT", "chat/11111111-2222-3333-4444-555555555555.png", 15*time.Minute, map[string]string{"Content-Type": "image/jpeg"})
	if sig(u) == sig(u2) {
		t.Fatal("changing the signed Content-Type must change the signature")
	}
	u3, _ := s.Presign("GET", "chat/11111111-2222-3333-4444-555555555555.png", 15*time.Minute, nil)
	if sig(u) == sig(u3) {
		t.Fatal("method must be part of the signature")
	}
}

func sig(u string) string { return u[strings.Index(u, "X-Amz-Signature="):] }

func TestS3StatUsesHead(t *testing.T) {
	var sawMethod string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sawMethod = r.Method
		if strings.Contains(r.URL.Path, "missing") {
			w.WriteHeader(404)
			return
		}
		w.Header().Set("Content-Length", "1234")
	}))
	defer srv.Close()
	s := &S3{Endpoint: srv.URL, Bucket: "b", Region: "auto", AccessKey: "a", SecretKey: "s", PathStyle: true}
	n, err := s.Stat(context.Background(), "chat/11111111-2222-3333-4444-555555555555.jpg")
	if err != nil || n != 1234 || sawMethod != "HEAD" {
		t.Fatalf("n=%d err=%v method=%s", n, err, sawMethod)
	}
	_, err = s.Stat(context.Background(), "chat/00000000-0000-0000-0000-missing00000.jpg")
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("want ErrNotFound, got %v", err)
	}
}

func TestValidKeyBlocksTraversal(t *testing.T) {
	ok := "chat/11111111-2222-3333-4444-555555555555.png"
	if !ValidKey(ok) {
		t.Fatal("good key rejected")
	}
	for _, k := range []string{"", "../etc/passwd", "chat/../x.png", "chat/11111111-2222-3333-4444-555555555555.svg",
		"chat/11111111-2222-3333-4444-555555555555.png/../../x", "/chat/11111111-2222-3333-4444-555555555555.png",
		"chat/11111111-2222-3333-4444-555555555555.PNG", "chat/zzzzzzzz-2222-3333-4444-555555555555.png"} {
		if ValidKey(k) {
			t.Errorf("dangerous key accepted: %q", k)
		}
	}
}

var (
	pngBytes  = append([]byte("\x89PNG\r\n\x1a\n"), bytes.Repeat([]byte{0}, 100)...)
	jpegBytes = append([]byte("\xff\xd8\xff\xe0\x00\x10JFIF"), bytes.Repeat([]byte{1}, 100)...)
)

const goodKey = "chat/11111111-2222-3333-4444-555555555555.png"

func TestLocalSaveOpenStat(t *testing.T) {
	l := &Local{Root: t.TempDir(), BaseURL: "https://api.example.com/"}
	n, err := l.Save(goodKey, "image/png", bytes.NewReader(pngBytes), 1<<20)
	if err != nil || n != int64(len(pngBytes)) {
		t.Fatalf("save: n=%d err=%v", n, err)
	}
	if sz, err := l.Stat(context.Background(), goodKey); err != nil || sz != n {
		t.Fatalf("stat: %d %v", sz, err)
	}
	f, err := l.Open(goodKey)
	if err != nil {
		t.Fatal(err)
	}
	f.Close()
	if fi, _ := os.Stat(filepath.Join(l.Root, goodKey)); fi.Mode().Perm() != 0o640 {
		t.Fatalf("perm %v", fi.Mode().Perm())
	}
	if _, err := l.Stat(context.Background(), "chat/99999999-2222-3333-4444-555555555555.png"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("want ErrNotFound, got %v", err)
	}
	u, _ := l.DownloadURL(context.Background(), "abc", goodKey, time.Hour)
	if u != "https://api.example.com/v1/media/abc" {
		t.Fatalf("url %s", u)
	}
}

func TestLocalRejectsWrongContentAndOversize(t *testing.T) {
	l := &Local{Root: t.TempDir()}
	if _, err := l.Save(goodKey, "image/png", strings.NewReader("<html><script>alert(1)</script></html>"), 1<<20); !errors.Is(err, ErrBadContent) {
		t.Fatalf("html as png: %v", err)
	}
	if _, err := l.Save(goodKey, "image/png", bytes.NewReader(jpegBytes), 1<<20); !errors.Is(err, ErrBadContent) {
		t.Fatalf("jpeg declared as png: %v", err)
	}
	if _, err := l.Save(goodKey, "image/png", bytes.NewReader(nil), 1<<20); !errors.Is(err, ErrBadContent) {
		t.Fatalf("empty: %v", err)
	}
	big := append(append([]byte{}, pngBytes...), bytes.Repeat([]byte{7}, 5000)...)
	if _, err := l.Save(goodKey, "image/png", bytes.NewReader(big), 1000); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("oversize: %v", err)
	}
	if _, err := l.Stat(context.Background(), goodKey); !errors.Is(err, ErrNotFound) {
		t.Fatal("a rejected upload must leave no file behind")
	}
	entries, _ := os.ReadDir(filepath.Join(l.Root, "chat"))
	for _, e := range entries {
		t.Errorf("leftover temp file: %s", e.Name())
	}
	if _, err := l.Save("../../etc/x.png", "image/png", bytes.NewReader(pngBytes), 1<<20); err == nil {
		t.Fatal("traversal key accepted")
	}
}

func TestLocalDeleteIsIdempotentAndRootCanBeRelative(t *testing.T) {
	l := &Local{Root: t.TempDir()}
	if _, err := l.Save(goodKey, "image/png", bytes.NewReader(pngBytes), 1<<20); err != nil {
		t.Fatal(err)
	}
	if err := l.Delete(context.Background(), goodKey); err != nil {
		t.Fatal(err)
	}
	if _, err := l.Stat(context.Background(), goodKey); !errors.Is(err, ErrNotFound) {
		t.Fatalf("file still there: %v", err)
	}
	if err := l.Delete(context.Background(), goodKey); err != nil {
		t.Fatalf("second delete must not fail: %v", err)
	}
	if err := l.Delete(context.Background(), "../../etc/passwd"); err == nil {
		t.Fatal("traversal accepted by Delete")
	}
	// a relative root (MEDIA_DIR=. or ./media_data) must work
	dir := t.TempDir()
	old, _ := os.Getwd()
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	defer os.Chdir(old)
	for _, root := range []string{".", "./media_data", "media_data"} {
		r := &Local{Root: root}
		if _, err := r.Save(goodKey, "image/png", bytes.NewReader(pngBytes), 1<<20); err != nil {
			t.Fatalf("root %q: %v", root, err)
		}
		if err := r.Delete(context.Background(), goodKey); err != nil {
			t.Fatalf("root %q delete: %v", root, err)
		}
	}
}

func TestS3DeleteUsesPresignedDelete(t *testing.T) {
	var sawMethod, sawQuery string
	status := 204
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sawMethod, sawQuery = r.Method, r.URL.RawQuery
		w.WriteHeader(status)
	}))
	defer srv.Close()
	s := &S3{Endpoint: srv.URL, Bucket: "b", Region: "auto", AccessKey: "a", SecretKey: "s", PathStyle: true}
	if err := s.Delete(context.Background(), goodKey); err != nil {
		t.Fatal(err)
	}
	if sawMethod != "DELETE" || !strings.Contains(sawQuery, "X-Amz-Signature=") {
		t.Fatalf("method=%s query=%s", sawMethod, sawQuery)
	}
	status = 404
	if err := s.Delete(context.Background(), goodKey); err != nil {
		t.Fatalf("404 means already gone: %v", err)
	}
	status = 403
	if err := s.Delete(context.Background(), goodKey); err == nil {
		t.Fatal("403 must be reported")
	}
}
