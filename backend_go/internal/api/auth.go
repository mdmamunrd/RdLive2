package api

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"rdlive/internal/auth"
)

// Max distinct accounts allowed per physical device (anti multi-account farming).
const maxAccountsPerDevice = 3

type userRow struct {
	ID          int64  `json:"id"`
	PublicID    int64  `json:"public_id"`
	DisplayName string `json:"display_name"`
	AvatarURL   string `json:"avatar_url"`
	Role        string `json:"role"`
	Status      string `json:"-"`
	Level       int    `json:"level"`
}

type socialReq struct {
	Provider   string `json:"provider"` // informational only: the verified token decides
	IDToken    string `json:"id_token"`
	DeviceID   string `json:"device_id"`
	Platform   string `json:"platform"`
	Model      string `json:"model"`
	AppVersion string `json:"app_version"`
	FCMToken   string `json:"fcm_token"`
	IsEmulator bool   `json:"is_emulator"` // client-reported; confirm with Play Integrity / App Attest
}

type tokenResp struct {
	AccessToken  string  `json:"access_token"`
	RefreshToken string  `json:"refresh_token"`
	ExpiresIn    int     `json:"expires_in"`
	User         userRow `json:"user"`
	IsNew        bool    `json:"is_new,omitempty"`
}

// POST /v1/auth/social
func (a *API) socialLogin(w http.ResponseWriter, r *http.Request) {
	var req socialReq
	if !decode(w, r, &req) {
		return
	}
	ctx := r.Context()
	if req.IDToken == "" {
		writeErr(w, http.StatusBadRequest, "bad_request", "id_token required")
		return
	}
	if a.Cfg.RequireDeviceID && (len(req.DeviceID) < 8 || len(req.DeviceID) > 128) {
		writeErr(w, http.StatusBadRequest, "device_required", "device_id required")
		return
	}
	if len(req.DeviceID) > 128 {
		req.DeviceID = ""
	}

	ident, err := a.Verifier.Verify(ctx, req.IDToken)
	if err != nil {
		code := http.StatusUnauthorized
		msg := "invalid token"
		if errors.Is(err, auth.ErrUnsupportedProvider) {
			code, msg = http.StatusBadRequest, "sign-in method not supported"
		}
		writeErr(w, code, "invalid_token", msg)
		return
	}

	ip := clientIP(r)
	// Block banned IP/device before we create any account.
	if blocked, err := a.isBlocked(ctx, nil, ip, req.DeviceID); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "try again")
		return
	} else if blocked {
		writeErr(w, http.StatusForbidden, "banned", "access denied")
		return
	}

	u, isNew, err := a.upsertUser(ctx, ident)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "could not sign in")
		return
	}
	if u.Status != "active" {
		writeErr(w, http.StatusForbidden, "account_blocked", "account is "+u.Status)
		return
	}
	if blocked, err := a.isBlocked(ctx, &u.ID, ip, req.DeviceID); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "try again")
		return
	} else if blocked {
		writeErr(w, http.StatusForbidden, "banned", "access denied")
		return
	}

	if req.DeviceID != "" {
		var n int
		err := a.DB.QueryRow(ctx, `
			select count(distinct user_id) from user_devices
			where device_id=$1 and user_id<>$2`, req.DeviceID, u.ID).Scan(&n)
		if err == nil && n >= maxAccountsPerDevice {
			writeErr(w, http.StatusForbidden, "device_limit", "too many accounts on this device")
			return
		}
		_, _ = a.DB.Exec(ctx, `
			insert into user_devices(user_id,device_id,platform,model,app_version,fcm_token,is_emulator,last_ip)
			values($1,$2,nullif($3,''),nullif($4,''),nullif($5,''),nullif($6,''),$7,nullif($8,'')::inet)
			on conflict (user_id,device_id) do update
			  set last_seen_at=now(), fcm_token=coalesce(excluded.fcm_token,user_devices.fcm_token),
			      is_emulator=excluded.is_emulator, last_ip=excluded.last_ip, app_version=excluded.app_version`,
			u.ID, req.DeviceID, validPlatform(req.Platform), req.Model, req.AppVersion, req.FCMToken, req.IsEmulator, ip)
	}
	_, _ = a.DB.Exec(ctx, `update users set last_login_at=now() where id=$1`, u.ID)

	resp, err := a.issuePair(ctx, nil, u, req.DeviceID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "could not sign in")
		return
	}
	resp.IsNew = isNew
	writeJSON(w, http.StatusOK, resp)
}

// POST /v1/auth/refresh  (rotates the refresh token)
func (a *API) refresh(w http.ResponseWriter, r *http.Request) {
	var req struct {
		RefreshToken string `json:"refresh_token"`
	}
	if !decode(w, r, &req) {
		return
	}
	if req.RefreshToken == "" {
		writeErr(w, http.StatusBadRequest, "bad_request", "refresh_token required")
		return
	}
	var resp tokenResp
	var denied string
	err := pgx.BeginFunc(r.Context(), a.DB, func(tx pgx.Tx) error {
		var uid int64
		var dev *string
		err := tx.QueryRow(r.Context(), `
			update refresh_tokens set revoked_at=now()
			where token_hash=$1 and revoked_at is null and expires_at>now()
			returning user_id, device_id`, auth.HashToken(req.RefreshToken)).Scan(&uid, &dev)
		if errors.Is(err, pgx.ErrNoRows) {
			denied = "invalid_refresh"
			return nil
		}
		if err != nil {
			return err
		}
		var u userRow
		if err := tx.QueryRow(r.Context(), `
			select id,public_id,display_name,coalesce(avatar_url,''),role::text,status::text,level
			from users where id=$1`, uid).Scan(&u.ID, &u.PublicID, &u.DisplayName, &u.AvatarURL, &u.Role, &u.Status, &u.Level); err != nil {
			return err
		}
		if u.Status != "active" {
			denied = "account_blocked"
			return nil
		}
		d := ""
		if dev != nil {
			d = *dev
		}
		resp, err = a.issuePair(r.Context(), tx, u, d)
		return err
	})
	switch {
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "try again")
	case denied == "account_blocked":
		writeErr(w, http.StatusForbidden, denied, "account blocked")
	case denied != "":
		writeErr(w, http.StatusUnauthorized, denied, "refresh token invalid or expired")
	default:
		writeJSON(w, http.StatusOK, resp)
	}
}

type execer interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

func (a *API) issuePair(ctx context.Context, tx execer, u userRow, deviceID string) (tokenResp, error) {
	access, err := a.Tokens.Issue(u.ID, u.Role)
	if err != nil {
		return tokenResp{}, err
	}
	raw, hash := auth.NewRefreshToken()
	var ex execer = a.DB
	if tx != nil {
		ex = tx
	}
	_, err = ex.Exec(ctx, `
		insert into refresh_tokens(user_id,token_hash,device_id,expires_at)
		values($1,$2,nullif($3,''),now()+($4::bigint * interval '1 second'))`,
		u.ID, hash, deviceID, int64(a.Cfg.RefreshTTL.Seconds()))
	if err != nil {
		return tokenResp{}, err
	}
	return tokenResp{AccessToken: access, RefreshToken: raw, ExpiresIn: int(a.Tokens.TTL().Seconds()), User: u}, nil
}

func (a *API) upsertUser(ctx context.Context, id *auth.Identity) (u userRow, isNew bool, err error) {
	for attempt := 0; attempt < 3; attempt++ {
		u, isNew = userRow{}, false
		err = pgx.BeginFunc(ctx, a.DB, func(tx pgx.Tx) error {
			const cols = `id,public_id,display_name,coalesce(avatar_url,''),role::text,status::text,level`
			e := tx.QueryRow(ctx, `
				select u.id,u.public_id,u.display_name,coalesce(u.avatar_url,''),u.role::text,u.status::text,u.level
				from auth_identities i join users u on u.id=i.user_id
				where i.provider=$1::auth_provider and i.provider_uid=$2`, id.Provider, id.UID).
				Scan(&u.ID, &u.PublicID, &u.DisplayName, &u.AvatarURL, &u.Role, &u.Status, &u.Level)
			if e == nil {
				return nil
			}
			if !errors.Is(e, pgx.ErrNoRows) {
				return e
			}
			e = tx.QueryRow(ctx, `
				insert into users(display_name,email,avatar_url)
				values($1,nullif($2,'')::citext,nullif($3,'')) returning `+cols,
				cleanName(id.Name), id.Email, id.Picture).
				Scan(&u.ID, &u.PublicID, &u.DisplayName, &u.AvatarURL, &u.Role, &u.Status, &u.Level)
			if e != nil {
				return e
			}
			_, e = tx.Exec(ctx, `
				insert into auth_identities(user_id,provider,provider_uid,email)
				values($1,$2::auth_provider,$3,nullif($4,'')::citext)`, u.ID, id.Provider, id.UID, id.Email)
			isNew = true
			return e
		})
		var pe *pgconn.PgError
		if errors.As(err, &pe) && pe.Code == "23505" { // lost a race / public_id collision: retry
			continue
		}
		return
	}
	return
}

func (a *API) isBlocked(ctx context.Context, uid *int64, ip, device string) (bool, error) {
	var ipArg any
	if ip != "" {
		ipArg = ip
	}
	var b bool
	err := a.DB.QueryRow(ctx, `
		select exists(
		  select 1 from bans
		  where lifted_at is null and (expires_at is null or expires_at>now())
		    and ( (target_type='ip'     and target_ip=$1::inet)
		       or (target_type='device' and $2::text<>'' and target_device=$2::text)
		       or (target_type='user'   and target_user=$3::bigint) ))`,
		ipArg, device, uid).Scan(&b)
	return b, err
}

func cleanName(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return "rdlive user"
	}
	if utf8.RuneCountInString(s) > 40 {
		s = string([]rune(s)[:40])
	}
	return s
}

func validPlatform(p string) string {
	if p == "android" || p == "ios" {
		return p
	}
	return ""
}

// GET /v1/me
func (a *API) me(w http.ResponseWriter, r *http.Request) {
	var u userRow
	var coins, diamonds int64
	err := a.DB.QueryRow(r.Context(), `
		select u.id,u.public_id,u.display_name,coalesce(u.avatar_url,''),u.role::text,u.level,w.coins,w.diamonds
		from users u join wallets w on w.user_id=u.id where u.id=$1`, userID(r.Context())).
		Scan(&u.ID, &u.PublicID, &u.DisplayName, &u.AvatarURL, &u.Role, &u.Level, &coins, &diamonds)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "try again")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"user": u, "wallet": map[string]int64{"coins": coins, "diamonds": diamonds}})
}
