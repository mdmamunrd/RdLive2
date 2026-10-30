package api

import (
	"errors"
	"net/http"
	"strings"
	"time"

	"rdlive/internal/media"
)

const uploadTTL = 15 * time.Minute

func (a *API) needMedia(w http.ResponseWriter) bool {
	if a.Media == nil {
		writeErr(w, http.StatusServiceUnavailable, "media_disabled", "image storage is not configured")
		return false
	}
	return true
}

// POST /v1/chat/media   {content_type, size_bytes, width?, height?}
// Step 1 of sending an image: reserve an id + get an upload target.
//
//	local storage : PUT <upload.url> with the raw bytes, Content-Type and your Authorization header
//	S3 / R2       : PUT <upload.url> with the raw bytes and the given Content-Type header (no Authorization!),
//	                then POST /v1/chat/media/{id}/complete
//
// Step 3: POST /v1/chat/conversations/{id}/messages {"kind":"image","media_id":...}
func (a *API) mediaCreate(w http.ResponseWriter, r *http.Request) {
	if !a.needMedia(w) {
		return
	}
	var req struct {
		ContentType string `json:"content_type"`
		SizeBytes   int64  `json:"size_bytes"`
		Width       *int32 `json:"width"`
		Height      *int32 `json:"height"`
	}
	if !decode(w, r, &req) {
		return
	}
	mime := strings.ToLower(strings.TrimSpace(req.ContentType))
	if !media.ValidMime(mime) {
		writeErr(w, http.StatusUnsupportedMediaType, "unsupported_media", "only jpeg, png, webp and gif images are allowed")
		return
	}
	if req.SizeBytes < 1 || req.SizeBytes > a.Cfg.MediaMaxBytes {
		writeErr(w, http.StatusRequestEntityTooLarge, "media_too_large", "image is too large")
		return
	}
	for _, d := range []*int32{req.Width, req.Height} {
		if d != nil && (*d < 1 || *d > 20000) {
			writeErr(w, http.StatusBadRequest, "bad_request", "invalid width/height")
			return
		}
	}
	var id, key string
	if err := a.DB.QueryRow(r.Context(), `select id::text, storage_key from media_create($1,$2,$3,$4,$5,$6)`,
		userID(r.Context()), mime, req.SizeBytes, req.Width, req.Height, a.Media.Kind()).Scan(&id, &key); err != nil {
		dbErr(w, "media_create", err)
		return
	}
	target, err := a.Media.UploadTarget(r.Context(), id, key, mime, req.SizeBytes, uploadTTL)
	if err != nil {
		dbErr(w, "media UploadTarget", err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"media_id": id, "upload": target, "expires_in": int(uploadTTL.Seconds()), "max_bytes": a.Cfg.MediaMaxBytes,
	})
}

type mediaRow struct {
	Owner  int64
	Key    string
	Mime   string
	Size   int64
	Status string
}

func (a *API) loadMedia(w http.ResponseWriter, r *http.Request, id string) (mediaRow, bool) {
	var m mediaRow
	if !uuidRe.MatchString(id) {
		writeErr(w, http.StatusNotFound, "media_not_found", "image not found")
		return m, false
	}
	err := a.DB.QueryRow(r.Context(), `
		select owner_id, storage_key, mime, size_bytes, status::text from media_assets where id=$1::uuid`, id).
		Scan(&m.Owner, &m.Key, &m.Mime, &m.Size, &m.Status)
	if err != nil {
		notFoundOr500(w, "loadMedia", err, "image")
		return m, false
	}
	return m, true
}

// PUT /v1/media/{id}/content      (local storage only) raw image bytes
func (a *API) mediaUploadLocal(w http.ResponseWriter, r *http.Request) {
	local, ok := a.Media.(*media.Local)
	if !ok || a.Media == nil {
		writeErr(w, http.StatusNotFound, "not_found", "direct upload is only used with local storage")
		return
	}
	id := pathString(r, "id")
	m, ok := a.loadMedia(w, r, id)
	if !ok {
		return
	}
	uid := userID(r.Context())
	if m.Owner != uid {
		writeErr(w, http.StatusNotFound, "media_not_found", "image not found") // do not reveal other people's ids
		return
	}
	if m.Status == "ready" {
		writeJSON(w, http.StatusOK, map[string]any{"media_id": id, "status": "ready", "size": m.Size})
		return
	}
	if m.Status != "pending" {
		writeErr(w, http.StatusConflict, "media_not_ready", "this upload slot is closed")
		return
	}
	if !strings.EqualFold(r.Header.Get("Content-Type"), m.Mime) {
		writeErr(w, http.StatusUnsupportedMediaType, "unsupported_media", "Content-Type must be "+m.Mime)
		return
	}
	if r.ContentLength > m.Size {
		writeErr(w, http.StatusRequestEntityTooLarge, "media_too_large", "image is larger than declared")
		return
	}
	// A slow mobile upload may exceed the server-wide ReadTimeout: give this request its own deadline.
	rc := http.NewResponseController(w)
	_ = rc.SetReadDeadline(time.Now().Add(2 * time.Minute))
	_ = rc.SetWriteDeadline(time.Now().Add(2*time.Minute + 10*time.Second))

	n, err := local.Save(m.Key, m.Mime, http.MaxBytesReader(w, r.Body, m.Size+1), m.Size)
	switch {
	case errors.Is(err, media.ErrTooLarge):
		writeErr(w, http.StatusRequestEntityTooLarge, "media_too_large", "image is larger than declared")
		return
	case errors.Is(err, media.ErrBadContent):
		writeErr(w, http.StatusUnsupportedMediaType, "unsupported_media", "file content does not match the declared type")
		return
	case err != nil:
		dbErr(w, "media save", err)
		return
	}
	if _, err := a.DB.Exec(r.Context(), `select media_mark_ready($1,$2::uuid,$3)`, uid, id, n); err != nil {
		dbErr(w, "media_mark_ready", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"media_id": id, "status": "ready", "size": n})
}

// POST /v1/chat/media/{id}/complete      after the client finished the upload (required for S3/R2; harmless for local)
func (a *API) mediaComplete(w http.ResponseWriter, r *http.Request) {
	if !a.needMedia(w) {
		return
	}
	id := pathString(r, "id")
	m, ok := a.loadMedia(w, r, id)
	if !ok {
		return
	}
	uid := userID(r.Context())
	if m.Owner != uid {
		writeErr(w, http.StatusNotFound, "media_not_found", "image not found")
		return
	}
	size, err := a.Media.Stat(r.Context(), m.Key)
	if errors.Is(err, media.ErrNotFound) {
		writeErr(w, http.StatusConflict, "media_not_ready", "the image has not been uploaded yet")
		return
	}
	if err != nil {
		dbErr(w, "media stat", err)
		return
	}
	if size < 1 || size > m.Size || size > a.Cfg.MediaMaxBytes { // never larger than what was declared
		writeErr(w, http.StatusRequestEntityTooLarge, "media_too_large", "uploaded image is larger than declared")
		return
	}
	if _, err := a.DB.Exec(r.Context(), `select media_mark_ready($1,$2::uuid,$3)`, uid, id, size); err != nil {
		dbErr(w, "media_mark_ready", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"media_id": id, "status": "ready", "size": size})
}

// GET /v1/media/{id}      (local storage) only the two chat participants (or the uploader) can read the file
func (a *API) mediaGet(w http.ResponseWriter, r *http.Request) {
	local, ok := a.Media.(*media.Local)
	if !ok || a.Media == nil {
		writeErr(w, http.StatusNotFound, "not_found", "not found")
		return
	}
	id := pathString(r, "id")
	if !uuidRe.MatchString(id) {
		writeErr(w, http.StatusNotFound, "media_not_found", "image not found")
		return
	}
	var allowed bool
	if err := a.DB.QueryRow(r.Context(), `select media_can_view($1,$2::uuid)`, userID(r.Context()), id).Scan(&allowed); err != nil {
		dbErr(w, "media_can_view", err)
		return
	}
	if !allowed {
		writeErr(w, http.StatusNotFound, "media_not_found", "image not found") // same answer as "does not exist"
		return
	}
	m, ok := a.loadMedia(w, r, id)
	if !ok {
		return
	}
	if m.Status != "ready" {
		writeErr(w, http.StatusNotFound, "media_not_found", "image not found")
		return
	}
	f, err := local.Open(m.Key)
	if err != nil {
		writeErr(w, http.StatusNotFound, "media_not_found", "image not found")
		return
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		dbErr(w, "media stat", err)
		return
	}
	h := w.Header()
	h.Set("Content-Type", m.Mime)
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Content-Security-Policy", "default-src 'none'; sandbox")
	h.Set("Cache-Control", "private, max-age=86400")
	http.ServeContent(w, r, "", fi.ModTime(), f)
}
