package media

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

// S3 signs AWS Signature V4 *query-string* (presigned) URLs by hand, so no SDK is needed.
// Works with AWS S3, Cloudflare R2, DigitalOcean Spaces and MinIO.
//
//	AWS S3 : Endpoint https://s3.<region>.amazonaws.com        PathStyle false
//	R2     : Endpoint https://<account>.r2.cloudflarestorage.com  PathStyle true,  Region "auto"
//	MinIO  : Endpoint http://localhost:9000                      PathStyle true
type S3 struct {
	Endpoint  string
	Bucket    string
	Region    string
	AccessKey string
	SecretKey string
	PathStyle bool

	HTTP *http.Client     // for Stat (HEAD); default 10s timeout
	Now  func() time.Time // tests
}

func (s *S3) Kind() string { return "s3" }

func (s *S3) now() time.Time {
	if s.Now != nil {
		return s.Now().UTC()
	}
	return time.Now().UTC()
}

// hostAndPath returns the Host header value and the canonical URI path for key.
func (s *S3) hostAndPath(key string) (scheme, host, path string, err error) {
	u, err := url.Parse(s.Endpoint)
	if err != nil || u.Host == "" {
		return "", "", "", fmt.Errorf("s3: bad endpoint %q", s.Endpoint)
	}
	if s.PathStyle {
		return u.Scheme, u.Host, "/" + s.Bucket + "/" + key, nil
	}
	return u.Scheme, s.Bucket + "." + u.Host, "/" + key, nil
}

// uriEncode implements the S3 canonical encoding (RFC 3986, '/' kept when asked).
func uriEncode(s string, keepSlash bool) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'A' && c <= 'Z', c >= 'a' && c <= 'z', c >= '0' && c <= '9', c == '-', c == '_', c == '.', c == '~':
			b.WriteByte(c)
		case c == '/' && keepSlash:
			b.WriteByte(c)
		default:
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}

func hmacSHA256(key []byte, data string) []byte {
	m := hmac.New(sha256.New, key)
	m.Write([]byte(data))
	return m.Sum(nil)
}

// Presign returns a presigned URL. signHeaders are extra headers that the caller MUST send with
// exactly these values (e.g. Content-Type for PUT).
func (s *S3) Presign(method, key string, ttl time.Duration, signHeaders map[string]string) (string, error) {
	scheme, host, path, err := s.hostAndPath(key)
	if err != nil {
		return "", err
	}
	t := s.now()
	date, stamp := t.Format("20060102"), t.Format("20060102T150405Z")
	scope := date + "/" + s.Region + "/s3/aws4_request"

	hdr := map[string]string{"host": host}
	for k, v := range signHeaders {
		hdr[strings.ToLower(k)] = strings.TrimSpace(v)
	}
	names := make([]string, 0, len(hdr))
	for k := range hdr {
		names = append(names, k)
	}
	sort.Strings(names)
	var canonHeaders strings.Builder
	for _, k := range names {
		canonHeaders.WriteString(k + ":" + hdr[k] + "\n")
	}
	signed := strings.Join(names, ";")

	q := map[string]string{
		"X-Amz-Algorithm":     "AWS4-HMAC-SHA256",
		"X-Amz-Credential":    s.AccessKey + "/" + scope,
		"X-Amz-Date":          stamp,
		"X-Amz-Expires":       strconv.Itoa(int(ttl.Seconds())),
		"X-Amz-SignedHeaders": signed,
	}
	keys := make([]string, 0, len(q))
	for k := range q {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	pairs := make([]string, 0, len(keys))
	for _, k := range keys {
		pairs = append(pairs, uriEncode(k, false)+"="+uriEncode(q[k], false))
	}
	canonQuery := strings.Join(pairs, "&")

	canonURI := uriEncode(path, true)
	canonical := strings.Join([]string{method, canonURI, canonQuery, canonHeaders.String(), signed, "UNSIGNED-PAYLOAD"}, "\n")
	sum := sha256.Sum256([]byte(canonical))
	toSign := "AWS4-HMAC-SHA256\n" + stamp + "\n" + scope + "\n" + hex.EncodeToString(sum[:])

	k := hmacSHA256([]byte("AWS4"+s.SecretKey), date)
	k = hmacSHA256(k, s.Region)
	k = hmacSHA256(k, "s3")
	k = hmacSHA256(k, "aws4_request")
	sig := hex.EncodeToString(hmacSHA256(k, toSign))

	return scheme + "://" + host + canonURI + "?" + canonQuery + "&X-Amz-Signature=" + sig, nil
}

func (s *S3) UploadTarget(_ context.Context, _ string, key, mime string, _ int64, ttl time.Duration) (UploadTarget, error) {
	u, err := s.Presign("PUT", key, ttl, map[string]string{"Content-Type": mime})
	if err != nil {
		return UploadTarget{}, err
	}
	return UploadTarget{Method: "PUT", URL: u, Headers: map[string]string{"Content-Type": mime}}, nil
}

func (s *S3) DownloadURL(_ context.Context, _ string, key string, ttl time.Duration) (string, error) {
	return s.Presign("GET", key, ttl, nil)
}

// Stat does a presigned HEAD to learn the uploaded size (and that the upload really happened).
func (s *S3) Stat(ctx context.Context, key string) (int64, error) {
	u, err := s.Presign("HEAD", key, time.Minute, nil)
	if err != nil {
		return 0, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodHead, u, nil)
	if err != nil {
		return 0, err
	}
	c := s.HTTP
	if c == nil {
		c = &http.Client{Timeout: 10 * time.Second}
	}
	resp, err := c.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusOK:
		return resp.ContentLength, nil
	case http.StatusNotFound:
		return 0, ErrNotFound
	}
	return 0, fmt.Errorf("s3: HEAD %s -> %d", key, resp.StatusCode)
}

// Delete issues a presigned DELETE. S3 answers 204 (also for a key that does not exist); 404 is fine too.
func (s *S3) Delete(ctx context.Context, key string) error {
	u, err := s.Presign("DELETE", key, time.Minute, nil)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, u, nil)
	if err != nil {
		return err
	}
	c := s.HTTP
	if c == nil {
		c = &http.Client{Timeout: 10 * time.Second}
	}
	resp, err := c.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusOK, http.StatusNoContent, http.StatusNotFound:
		return nil
	}
	return fmt.Errorf("s3: DELETE %s -> %d", key, resp.StatusCode)
}
