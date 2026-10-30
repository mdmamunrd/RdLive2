package api

import (
	"net/http"
	"regexp"
	"strconv"

	"github.com/go-chi/chi/v5"
)

var uuidRe = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// pathInt reads a positive integer URL parameter; it writes a 400 itself on failure.
func pathInt(w http.ResponseWriter, r *http.Request, name string) (int64, bool) {
	n, err := strconv.ParseInt(chi.URLParam(r, name), 10, 64)
	if err != nil || n < 0 {
		writeErr(w, http.StatusBadRequest, "bad_request", "invalid "+name)
		return 0, false
	}
	return n, true
}

func pathString(r *http.Request, name string) string { return chi.URLParam(r, name) }
