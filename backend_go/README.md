# rdlive backend (Go) — Auth, Wallet/Recharge, Gifts

## Run
```bash
go mod tidy                      # fetch deps (chi, pgx, jwt, x/time)
psql "$DATABASE_URL" -f ../database_sql/schema.sql
go test ./...
go run ./cmd/api
```

## Env
| Var | Required | Notes |
|---|---|---|
| DATABASE_URL | yes | postgres://user:pass@host/db |
| JWT_SECRET | yes | >= 32 chars |
| FIREBASE_PROJECT_ID | yes | verifies Firebase ID tokens (Google/Facebook) |
| PUBLIC_BASE_URL | yes | public https URL of this API (gateway callbacks) |
| APP_RETURN_URL | no | deep link, default `rdlive://payment` |
| REQUIRE_DEVICE_ID | no | `true` to force device_id on login |
| BKASH_BASE_URL / _APP_KEY / _APP_SECRET / _USERNAME / _PASSWORD | for bKash | |
| STRIPE_SECRET_KEY / STRIPE_WEBHOOK_SECRET | for card | |

## Endpoints
| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | /v1/auth/social | – | `{id_token, device_id?, ...}` -> access + refresh token |
| POST | /v1/auth/refresh | – | rotate refresh token |
| GET | /v1/me | Bearer | profile + wallet |
| GET | /v1/wallet | Bearer | coins, diamonds, rate |
| GET | /v1/wallet/ledger | Bearer | passbook (cursor: before_id) |
| GET | /v1/recharge/packages | Bearer | packages + available providers |
| POST | /v1/recharge/orders | Bearer | `{package_id, provider}` -> `payment_url` |
| GET | /v1/recharge/orders/{id} | Bearer | poll status |
| ANY | /webhooks/{provider} | signature | bKash redirect callback, Stripe webhook |
| GET | /v1/gifts | Bearer | catalogue |
| POST | /v1/gifts/send | Bearer + `Idempotency-Key` | runs `send_gift()` |

## Money safety
- Amount/coins always come from `recharge_packages`, never from the client.
- Webhook must match order provider, amount and currency, else it is logged and NOT credited.
- Crediting happens only in `settle_recharge()` (idempotent, row-locked).
- Gifts are idempotent per `(sender, Idempotency-Key)`.

## Not implemented yet
- Nagad / Rocket (registered, answer 501). Nagad needs merchant RSA keys; Rocket is usually via an aggregator.
- PayPal, withdrawals endpoints, reconcile job for pending bKash orders.

## Coin distribution & portal APIs (needs `database_sql/003_coin_distribution.sql`)

Roles are re-read from the database on every request (the JWT `role` claim is ignored). Money-moving `POST`s require an
`Idempotency-Key` header (8-64 chars `[A-Za-z0-9_\-:.]`); keys are namespaced per user server-side.

| Role | Endpoint | Purpose |
|---|---|---|
| super_admin | `POST /v1/admin/sellers` · `GET /v1/admin/sellers` · `PATCH /v1/admin/sellers/{id}` | create / list / suspend sellers, change limits |
| super_admin | `POST /v1/admin/coins/mint` · `POST /v1/admin/coins/reclaim` | Master -> Seller mint; burn coins from any wallet |
| super_admin | `GET /v1/admin/coins/transfers` · `/coins/audit` · `/wallets/{publicID}` | history, integrity audit, balance check |
| coin_seller | `GET /v1/seller/me` · `/lookup` · `/transfers`, `POST /v1/seller/transfers` | balance, recipient lookup, history, sell coins |
| host | `GET /v1/host/earnings/today` | today's diamonds / gifts |

Set `PORTAL_ORIGINS` (comma separated, no wildcard) to let the web portals call the API from a browser.
Error mapping lives in `internal/coinx` (`go test ./internal/coinx`).

## Realtime, PK ticker, follows, chat (needs `database_sql/004_follows_chat.sql` and `005_media_cleanup.sql`)
- Migrations order: `schema.sql, 002, 003, 004, 005`.
- `GET /v1/ws`: first frame `{"op":"auth","token":...}`; ops `subscribe_room|unsubscribe_room|typing|ping`; server frames `ready, ack, error, room_event, chat_message, chat_read, typing, pong, resync`. On `resync` re-fetch state over REST.
- Listener: `internal/pgnotify` (pgx LISTEN) -> `internal/realtime` (Dispatcher/Hub), reconnect with backoff. PK ticker: `internal/worker` every `PK_TICK_SECONDS` (2-5, default 3). Media janitor runs hourly.
- REST: `/v1/users/{publicID}/follow|block`, `/v1/me/following|followers`, `/v1/rooms?tab=follow`, `/v1/chat/*`, `/v1/media/*` (see root `README.bn.md` section 11).
- Tests: `go test -race ./internal/...`; PG integration: `RD_PSQL_ARGS="-h HOST -p PORT -U USER -d DB" go test -tags pgintegration -run PG ./internal/realtime` (DB needs the seed users c1,c3,c4 and a live room).
- Not verified here: build against real pgx/chi/jwt. Run `go mod tidy && go build ./... && go test ./...` first.
