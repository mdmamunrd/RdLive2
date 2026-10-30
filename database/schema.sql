-- =====================================================================
-- rdlive : PostgreSQL schema  (PostgreSQL 14+)
-- Modules: Users/Auth, Wallet & Ledger, Payments/Withdrawals,
--          Gifts & Entrance Effects, Agencies & Host Targets
-- Money rule: balances are only changed through wallet_apply(), which
-- locks the wallet row, writes an IMMUTABLE ledger row and enforces
-- idempotency. There is intentionally NO user-to-user coin transfer.
-- =====================================================================

create extension if not exists pgcrypto;
create extension if not exists citext;

-- ---------------------------------------------------------------------
-- ENUMS
-- ---------------------------------------------------------------------
create type user_role        as enum ('user','host','agency_owner','moderator','admin','super_admin');
create type auth_provider    as enum ('google','facebook','phone');
create type account_status   as enum ('active','suspended','banned','deleted');
create type kyc_status       as enum ('none','pending','verified','rejected');
create type asset_type       as enum ('coin','diamond');
create type tx_type          as enum (
  'recharge','gift_sent','gift_received','withdrawal','withdrawal_refund',
  'conversion_out','conversion_in','daily_reward','task_reward','game_bet','game_win',
  'admin_adjust','purchase_effect','refund'
);
create type pay_provider     as enum ('bkash','nagad','rocket','card','paypal');
create type order_status     as enum ('created','pending','paid','failed','cancelled','refunded');
create type withdraw_status  as enum ('pending','approved','processing','paid','rejected','cancelled');
create type payout_account   as enum ('bkash','nagad','rocket','bank','paypal');
create type ban_target       as enum ('user','ip','device');
create type payee_type       as enum ('host','agency');
create type target_status    as enum ('in_progress','achieved','missed','paid');
create type gift_category    as enum ('normal','lucky','premium','event');

-- ---------------------------------------------------------------------
-- HELPERS
-- ---------------------------------------------------------------------
create or replace function set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

-- =====================================================================
-- 1. USERS & AUTH
-- =====================================================================
create table level_configs (
  level        smallint primary key check (level between 1 and 100),
  required_xp  bigint not null check (required_xp >= 0),
  title        text,
  frame_url    text,            -- dynamic profile frame
  name_style   jsonb default '{}'::jsonb,   -- shining-name colours/animation
  entrance_badge_url text
);

create table users (
  id               bigint generated always as identity primary key,
  public_id        bigint  not null unique
                   default (10000000 + floor(random()*89999999))::bigint,  -- user-facing ID (retry on conflict)
  display_name     text    not null,
  email            citext,
  phone_e164       text unique,
  avatar_url       text,
  bio              text,
  gender           text check (gender in ('male','female','other')),
  birth_date       date,
  country_code     char(2) default 'BD',
  language         text    not null default 'en',       -- en | bn | hi ...
  role             user_role      not null default 'user',
  status           account_status not null default 'active',
  kyc              kyc_status     not null default 'none',
  level            smallint not null default 1 references level_configs(level),
  xp               bigint   not null default 0 check (xp >= 0),
  total_recharged_coins bigint not null default 0,
  total_gifted_coins    bigint not null default 0,
  is_vip           boolean not null default false,
  last_login_at    timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index users_email_idx   on users (email);
create index users_role_idx    on users (role) where role <> 'user';
create index users_status_idx  on users (status) where status <> 'active';
create trigger users_upd before update on users for each row execute function set_updated_at();

-- One user can link several identities (Google + Facebook + phone)
create table auth_identities (
  id            bigint generated always as identity primary key,
  user_id       bigint not null references users(id) on delete cascade,
  provider      auth_provider not null,
  provider_uid  text not null,                -- Google "sub" / Facebook user id
  email         citext,
  raw_profile   jsonb,
  created_at    timestamptz not null default now(),
  unique (provider, provider_uid)
);
create index auth_identities_user_idx on auth_identities (user_id);

create table refresh_tokens (
  id          uuid primary key default gen_random_uuid(),
  user_id     bigint not null references users(id) on delete cascade,
  token_hash  text   not null unique,         -- store SHA-256, never the raw token
  device_id   text,
  expires_at  timestamptz not null,
  revoked_at  timestamptz,
  created_at  timestamptz not null default now()
);
create index refresh_tokens_user_idx on refresh_tokens (user_id);

-- Hardware / device tracking for multi-account farming and emulator checks
create table user_devices (
  id            bigint generated always as identity primary key,
  user_id       bigint not null references users(id) on delete cascade,
  device_id     text   not null,              -- hashed hardware identifier
  platform      text   check (platform in ('android','ios')),
  model         text,
  app_version   text,
  fcm_token     text,
  is_emulator   boolean not null default false,
  is_rooted     boolean not null default false,
  vpn_suspected boolean not null default false,
  last_ip       inet,
  first_seen_at timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  unique (user_id, device_id)
);
create index user_devices_device_idx on user_devices (device_id);  -- find many accounts on one device

-- Multi-level bans: user id / IP / hardware device id
create table bans (
  id          bigint generated always as identity primary key,
  target_type ban_target not null,
  target_user bigint references users(id),
  target_ip   inet,
  target_device text,
  reason      text not null,
  banned_by   bigint references users(id),
  expires_at  timestamptz,                    -- null = permanent
  lifted_at   timestamptz,
  created_at  timestamptz not null default now(),
  check (
    (target_type='user'   and target_user   is not null) or
    (target_type='ip'     and target_ip     is not null) or
    (target_type='device' and target_device is not null)
  )
);
create index bans_ip_idx     on bans (target_ip)     where target_type='ip'     and lifted_at is null;
create index bans_device_idx on bans (target_device) where target_type='device' and lifted_at is null;
create index bans_user_idx   on bans (target_user)   where target_type='user'   and lifted_at is null;

-- Minimal room table (full room/seat/PK schema comes in the next module)
create table live_rooms (
  id            bigint generated always as identity primary key,
  host_id       bigint not null references users(id),
  title         text,
  seat_count    smallint not null default 8 check (seat_count in (4,6,8,9,12)),
  password_hash text,
  agora_channel text not null unique,
  status        text not null default 'live' check (status in ('live','ended')),
  started_at    timestamptz not null default now(),
  ended_at      timestamptz
);
create index live_rooms_host_idx on live_rooms (host_id, started_at desc);

-- =====================================================================
-- 2. WALLET & LEDGER
-- =====================================================================
create table wallets (
  user_id    bigint primary key references users(id) on delete cascade,
  coins      bigint not null default 0 check (coins    >= 0),   -- bought/spend currency
  diamonds   bigint not null default 0 check (diamonds >= 0),   -- earned by hosts
  updated_at timestamptz not null default now()
);

-- auto-create wallet with the user
create or replace function create_wallet() returns trigger language plpgsql as $$
begin insert into wallets(user_id) values (new.id); return new; end $$;
create trigger users_wallet after insert on users for each row execute function create_wallet();

-- Append-only ledger: every balance change has exactly one row
create table wallet_ledger (
  id              bigint generated always as identity primary key,
  user_id         bigint not null references users(id),
  asset           asset_type not null,
  amount          bigint not null check (amount <> 0),          -- +credit / -debit
  balance_after   bigint not null check (balance_after >= 0),
  tx_type         tx_type not null,
  ref_type        text,                                          -- 'recharge_order','gift_tx','withdrawal'...
  ref_id          text,
  idempotency_key text not null unique,
  meta            jsonb not null default '{}'::jsonb,
  created_at      timestamptz not null default now()
);
create index wallet_ledger_user_idx on wallet_ledger (user_id, created_at desc);
create index wallet_ledger_ref_idx  on wallet_ledger (ref_type, ref_id);

create or replace function ledger_immutable() returns trigger language plpgsql as $$
begin raise exception 'wallet_ledger is append-only'; end $$;
create trigger wallet_ledger_no_upd before update or delete on wallet_ledger
  for each row execute function ledger_immutable();

-- The ONLY way to move money. Idempotent and race-safe.
create or replace function wallet_apply(
  p_user bigint, p_asset asset_type, p_amount bigint, p_type tx_type,
  p_ref_type text, p_ref_id text, p_idem text, p_meta jsonb default '{}'::jsonb
) returns bigint language plpgsql as $$
declare cur bigint; nxt bigint; lid bigint;
begin
  select id into lid from wallet_ledger where idempotency_key = p_idem;
  if found then return lid; end if;                         -- replay: no double credit

  if p_asset = 'coin' then
    select coins    into cur from wallets where user_id = p_user for update;
  else
    select diamonds into cur from wallets where user_id = p_user for update;
  end if;
  if cur is null then raise exception 'wallet not found for user %', p_user; end if;

  nxt := cur + p_amount;
  if nxt < 0 then raise exception 'insufficient % balance', p_asset using errcode = 'P0001'; end if;

  if p_asset = 'coin' then
    update wallets set coins    = nxt, updated_at = now() where user_id = p_user;
  else
    update wallets set diamonds = nxt, updated_at = now() where user_id = p_user;
  end if;

  insert into wallet_ledger(user_id, asset, amount, balance_after, tx_type, ref_type, ref_id, idempotency_key, meta)
  values (p_user, p_asset, p_amount, nxt, p_type, p_ref_type, p_ref_id, p_idem, p_meta)
  returning id into lid;
  return lid;
end $$;

-- Diamond -> cash rate history (admin editable, real-time lookup = latest row)
create table exchange_rates (
  id             bigint generated always as identity primary key,
  diamonds_per_bdt numeric(12,4) not null check (diamonds_per_bdt > 0),  -- e.g. 100 diamonds = 1 BDT
  diamonds_per_usd numeric(12,4) check (diamonds_per_usd > 0),
  effective_from timestamptz not null default now(),
  set_by         bigint references users(id)
);
create index exchange_rates_eff_idx on exchange_rates (effective_from desc);

-- =====================================================================
-- 3. PAYMENTS (recharge) & WITHDRAWALS
-- =====================================================================
create table recharge_packages (
  id          int generated always as identity primary key,
  coins       bigint  not null check (coins > 0),
  bonus_coins bigint  not null default 0,
  price_bdt   numeric(12,2) not null check (price_bdt > 0),
  price_usd   numeric(12,2),
  is_active   boolean not null default true,
  sort_order  int not null default 0
);

create table recharge_orders (
  id              uuid primary key default gen_random_uuid(),
  user_id         bigint not null references users(id),
  package_id      int references recharge_packages(id),
  provider        pay_provider not null,
  amount          numeric(12,2) not null check (amount > 0),
  currency        char(3) not null default 'BDT',
  coins_granted   bigint not null check (coins_granted > 0),
  status          order_status not null default 'created',
  provider_trx_id text,                    -- bKash trxID / Nagad payment ref / Stripe id
  provider_payment_id text,                -- bKash paymentID etc.
  payer_account   text,                    -- masked wallet number
  paid_at         timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
-- same gateway transaction can never credit twice
create unique index recharge_orders_provider_trx_uq
  on recharge_orders (provider, provider_trx_id) where provider_trx_id is not null;
create index recharge_orders_user_idx   on recharge_orders (user_id, created_at desc);
create index recharge_orders_status_idx on recharge_orders (status) where status in ('created','pending');
create trigger recharge_orders_upd before update on recharge_orders for each row execute function set_updated_at();

-- Raw webhook/callback log for audit + dedupe
create table payment_webhook_events (
  id           bigint generated always as identity primary key,
  provider     pay_provider not null,
  event_id     text,
  signature_ok boolean not null,
  payload      jsonb not null,
  processed_at timestamptz,
  error        text,
  received_at  timestamptz not null default now(),
  unique (provider, event_id)
);

-- Called after verifying the gateway callback. Credits coins exactly once.
create or replace function settle_recharge(p_order uuid, p_provider_trx text) returns void
language plpgsql as $$
declare o recharge_orders%rowtype;
begin
  select * into o from recharge_orders where id = p_order for update;
  if not found then raise exception 'order not found'; end if;
  if o.status = 'paid' then return; end if;
  update recharge_orders set status='paid', provider_trx_id=p_provider_trx, paid_at=now() where id = p_order;
  perform wallet_apply(o.user_id,'coin',o.coins_granted,'recharge','recharge_order',o.id::text,'recharge:'||o.id::text);
  update users set total_recharged_coins = total_recharged_coins + o.coins_granted,
                   xp = xp + o.coins_granted where id = o.user_id;
end $$;

create table withdrawal_requests (
  id              uuid primary key default gen_random_uuid(),
  payee_type      payee_type not null,
  user_id         bigint not null references users(id),       -- host or agency owner
  agency_id       bigint,                                      -- FK added after agencies table
  diamonds        bigint not null check (diamonds > 0),
  rate_id         bigint not null references exchange_rates(id),
  amount_bdt      numeric(14,2) not null check (amount_bdt > 0),
  method          payout_account not null,
  account_number  text not null,
  account_name    text,
  status          withdraw_status not null default 'pending',
  reviewed_by     bigint references users(id),
  reviewed_at     timestamptz,
  reject_reason   text,
  payout_trx_id   text,
  paid_at         timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index withdrawal_status_idx on withdrawal_requests (status, created_at);
create index withdrawal_user_idx   on withdrawal_requests (user_id, created_at desc);
create trigger withdrawal_upd before update on withdrawal_requests for each row execute function set_updated_at();

-- Request = lock diamonds immediately (debit); reject = refund
create or replace function request_withdrawal(
  p_user bigint, p_diamonds bigint, p_method payout_account, p_acc text, p_name text, p_idem text
) returns uuid language plpgsql as $$
declare r exchange_rates%rowtype; wid uuid;
begin
  select * into r from exchange_rates where effective_from <= now() order by effective_from desc limit 1;
  if not found then raise exception 'no exchange rate configured'; end if;
  insert into withdrawal_requests(payee_type,user_id,diamonds,rate_id,amount_bdt,method,account_number,account_name)
  values ('host',p_user,p_diamonds,r.id,round(p_diamonds / r.diamonds_per_bdt,2),p_method,p_acc,p_name)
  returning id into wid;
  perform wallet_apply(p_user,'diamond',-p_diamonds,'withdrawal','withdrawal',wid::text,p_idem);
  return wid;
end $$;

create or replace function reject_withdrawal(p_id uuid, p_admin bigint, p_reason text) returns void
language plpgsql as $$
declare w withdrawal_requests%rowtype;
begin
  select * into w from withdrawal_requests where id=p_id for update;
  if w.status not in ('pending','approved') then raise exception 'cannot reject in status %', w.status; end if;
  update withdrawal_requests set status='rejected', reviewed_by=p_admin, reviewed_at=now(), reject_reason=p_reason where id=p_id;
  perform wallet_apply(w.user_id,'diamond',w.diamonds,'withdrawal_refund','withdrawal',p_id::text,'wd_refund:'||p_id::text);
end $$;

-- =====================================================================
-- 4. VIRTUAL GIFTS & ENTRANCE EFFECTS
-- =====================================================================
create table gifts (
  id            int generated always as identity primary key,
  name          text not null,
  category      gift_category not null default 'normal',
  price_coins   bigint not null check (price_coins > 0),
  diamond_value bigint not null check (diamond_value >= 0),   -- host earns this per unit
  icon_url      text,
  animation_url text,           -- Lottie / SVGA / MP4 for full-screen effect
  animation_type text check (animation_type in ('lottie','svga','mp4','webp')),
  is_full_screen boolean not null default false,
  min_level     smallint not null default 1,
  is_active     boolean not null default true,
  sort_order    int not null default 0,
  created_at    timestamptz not null default now()
);

create table gift_transactions (
  id               bigint generated always as identity primary key,
  sender_id        bigint not null references users(id),
  receiver_id      bigint not null references users(id),
  room_id          bigint references live_rooms(id),
  gift_id          int    not null references gifts(id),
  quantity         int    not null check (quantity between 1 and 9999),
  coins_spent      bigint not null,
  diamonds_earned  bigint not null,
  idempotency_key  text   not null unique,
  created_at       timestamptz not null default now(),
  check (sender_id <> receiver_id)
);
create index gift_tx_receiver_idx on gift_transactions (receiver_id, created_at desc);
create index gift_tx_sender_idx   on gift_transactions (sender_id,   created_at desc);
create index gift_tx_room_idx     on gift_transactions (room_id, created_at);
create index gift_tx_time_idx     on gift_transactions (created_at);    -- leaderboards

create table entrance_effects (
  id            int generated always as identity primary key,
  name          text not null,
  animation_url text not null,
  price_coins   bigint not null default 0,      -- 0 = unlock by level/VIP only
  min_level     smallint not null default 1,
  vip_only      boolean not null default false,
  is_active     boolean not null default true
);

create table user_entrance_effects (
  user_id     bigint not null references users(id) on delete cascade,
  effect_id   int    not null references entrance_effects(id),
  is_equipped boolean not null default false,
  acquired_at timestamptz not null default now(),
  expires_at  timestamptz,
  primary key (user_id, effect_id)
);
-- at most one equipped effect per user
create unique index user_effect_equipped_uq on user_entrance_effects (user_id) where is_equipped;

-- Atomic gift send: coin debit + diamond credit + stats + XP in ONE transaction
create or replace function send_gift(
  p_sender bigint, p_receiver bigint, p_room bigint, p_gift int, p_qty int, p_idem text
) returns bigint language plpgsql as $$
declare g gifts%rowtype; cost bigint; earn bigint; gid bigint; lvl smallint; lv smallint;
begin
  select id into gid from gift_transactions where idempotency_key = p_idem;
  if found then return gid; end if;

  if p_sender = p_receiver then raise exception 'cannot gift yourself'; end if;
  select * into g from gifts where id = p_gift and is_active;
  if not found then raise exception 'gift not available'; end if;
  select level into lv from users where id = p_sender;
  if lv < g.min_level then raise exception 'level too low for this gift'; end if;

  cost := g.price_coins   * p_qty;
  earn := g.diamond_value * p_qty;

  insert into gift_transactions(sender_id,receiver_id,room_id,gift_id,quantity,coins_spent,diamonds_earned,idempotency_key)
  values (p_sender,p_receiver,p_room,p_gift,p_qty,cost,earn,p_idem) returning id into gid;

  perform wallet_apply(p_sender,  'coin',    -cost,'gift_sent',    'gift_tx',gid::text,p_idem||':c');
  perform wallet_apply(p_receiver,'diamond',  earn,'gift_received','gift_tx',gid::text,p_idem||':d');

  update users set total_gifted_coins = total_gifted_coins + cost, xp = xp + cost where id = p_sender;
  select max(lc.level) into lvl from level_configs lc, users u where u.id = p_sender and lc.required_xp <= u.xp;
  update users set level = coalesce(lvl,1) where id = p_sender and level <> coalesce(lvl,1);

  -- host daily stats (feeds targets/salary)
  insert into host_daily_stats(host_id, stat_date, diamonds_earned)
  values (p_receiver, current_date, earn)
  on conflict (host_id, stat_date) do update set diamonds_earned = host_daily_stats.diamonds_earned + earn;

  return gid;
end $$;

-- =====================================================================
-- 5. AGENCIES & HOST TARGET MANAGEMENT
-- =====================================================================
create table agencies (
  id                bigint generated always as identity primary key,
  code              text not null unique,                 -- shown to hosts when joining
  name              text not null,
  owner_user_id     bigint not null unique references users(id),
  commission_bp     int not null default 1000 check (commission_bp between 0 and 10000),  -- 1000 = 10%
  contact_phone     text,
  country_code      char(2) default 'BD',
  status            text not null default 'active' check (status in ('pending','active','suspended')),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create trigger agencies_upd before update on agencies for each row execute function set_updated_at();

alter table withdrawal_requests
  add constraint withdrawal_agency_fk foreign key (agency_id) references agencies(id);

create table host_profiles (
  user_id        bigint primary key references users(id) on delete cascade,
  agency_id      bigint references agencies(id),
  host_code      text unique,
  approved_at    timestamptz,
  approved_by    bigint references users(id),
  status         text not null default 'pending' check (status in ('pending','active','suspended','left')),
  joined_agency_at timestamptz,
  created_at     timestamptz not null default now()
);
create index host_profiles_agency_idx on host_profiles (agency_id) where status = 'active';

-- Salary / target tiers (global default; agency_id for overrides)
create table target_tiers (
  id             int generated always as identity primary key,
  agency_id      bigint references agencies(id),          -- null = platform default
  tier_name      text not null,                           -- 'Bronze','Silver'...
  min_live_hours numeric(6,2) not null check (min_live_hours >= 0),
  min_live_days  smallint not null default 0,
  min_diamonds   bigint not null check (min_diamonds >= 0),
  salary_bdt     numeric(12,2) not null check (salary_bdt >= 0),
  bonus_bp       int not null default 0,                  -- extra % on diamonds
  sort_order     int not null default 0,
  is_active      boolean not null default true
);

create table host_live_sessions (
  id          bigint generated always as identity primary key,
  host_id     bigint not null references users(id),
  room_id     bigint references live_rooms(id),
  started_at  timestamptz not null,
  ended_at    timestamptz,
  seconds     int generated always as (
                case when ended_at is null then null
                     else greatest(0, extract(epoch from (ended_at - started_at))::int) end
              ) stored
);
create index host_sessions_idx on host_live_sessions (host_id, started_at desc);

create table host_daily_stats (
  host_id          bigint not null references users(id),
  stat_date        date   not null,
  live_seconds     int    not null default 0,
  diamonds_earned  bigint not null default 0,
  gift_count       int    not null default 0,
  primary key (host_id, stat_date)
);
create index host_daily_date_idx on host_daily_stats (stat_date);

-- Monthly target record: computed by cron from daily stats
create table host_monthly_targets (
  id               bigint generated always as identity primary key,
  host_id          bigint not null references users(id),
  agency_id        bigint references agencies(id),
  period_month     date   not null,                        -- first day of month
  live_seconds     bigint not null default 0,
  live_days        smallint not null default 0,
  diamonds_earned  bigint not null default 0,
  tier_id          int references target_tiers(id),
  salary_bdt       numeric(12,2) not null default 0,
  agency_commission_bdt numeric(12,2) not null default 0,
  status           target_status not null default 'in_progress',
  finalized_at     timestamptz,
  unique (host_id, period_month)
);
create index host_targets_agency_idx on host_monthly_targets (agency_id, period_month);

-- Payout ledger (salary + agency commission), separate from the coin wallet
create table payout_ledger (
  id            bigint generated always as identity primary key,
  payee_type    payee_type not null,
  user_id       bigint references users(id),
  agency_id     bigint references agencies(id),
  period_month  date,
  kind          text not null check (kind in ('host_salary','agency_commission','withdrawal_paid','adjustment')),
  amount_bdt    numeric(14,2) not null,                    -- +accrual / -paid
  ref_type      text,
  ref_id        text,
  note          text,
  created_by    bigint references users(id),
  created_at    timestamptz not null default now(),
  check (user_id is not null or agency_id is not null)
);
create index payout_ledger_user_idx   on payout_ledger (user_id, created_at desc);
create index payout_ledger_agency_idx on payout_ledger (agency_id, created_at desc);
create trigger payout_ledger_no_upd before update or delete on payout_ledger
  for each row execute function ledger_immutable();

-- Month-end finalisation: picks the highest tier the host qualifies for
create or replace function finalize_host_month(p_month date) returns int language plpgsql as $$
declare n int := 0; r record; t target_tiers%rowtype; a agencies%rowtype; comm numeric; ok boolean;
begin
  for r in
    select h.user_id, h.agency_id,
           coalesce(sum(s.live_seconds),0)            as secs,
           count(*) filter (where s.live_seconds > 0) as days,
           coalesce(sum(s.diamonds_earned),0)         as dia
    from host_profiles h
    left join host_daily_stats s
      on s.host_id = h.user_id
     and s.stat_date >= p_month and s.stat_date < (p_month + interval '1 month')
    where h.status = 'active'
    group by h.user_id, h.agency_id
  loop
    select * into t from target_tiers
     where is_active
       and (agency_id = r.agency_id or agency_id is null)
       and min_live_hours <= r.secs / 3600.0
       and min_live_days  <= r.days
       and min_diamonds   <= r.dia
     order by (agency_id is not null) desc, salary_bdt desc limit 1;
    ok := found;                      -- FOUND is reset by later statements

    comm := 0;
    if r.agency_id is not null and ok then
      select * into a from agencies where id = r.agency_id;
      comm := round(t.salary_bdt * a.commission_bp / 10000.0, 2);
    end if;

    insert into host_monthly_targets
      (host_id, agency_id, period_month, live_seconds, live_days, diamonds_earned,
       tier_id, salary_bdt, agency_commission_bdt, status, finalized_at)
    values (r.user_id, r.agency_id, p_month, r.secs, r.days, r.dia,
            case when ok then t.id end, case when ok then t.salary_bdt else 0 end, comm,
            case when ok then 'achieved' else 'missed' end::target_status, now())
    on conflict (host_id, period_month) do nothing;

    if ok then
      insert into payout_ledger(payee_type,user_id,period_month,kind,amount_bdt,ref_type,ref_id)
      values ('host', r.user_id, p_month, 'host_salary', t.salary_bdt, 'monthly_target', r.user_id::text);
      if comm > 0 then
        insert into payout_ledger(payee_type,agency_id,period_month,kind,amount_bdt,ref_type,ref_id)
        values ('agency', r.agency_id, p_month, 'agency_commission', comm, 'monthly_target', r.user_id::text);
      end if;
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

-- =====================================================================
-- SEED DATA (edit to your business rules)
-- =====================================================================
insert into level_configs(level, required_xp, title)
select l, (100 * l * l)::bigint - 100, 'Lv.'||l from generate_series(1,100) l;

insert into exchange_rates(diamonds_per_bdt, diamonds_per_usd) values (100, 8000);

insert into recharge_packages(coins, bonus_coins, price_bdt, price_usd, sort_order) values
  (1000,   0,  100,  1.0, 1),
  (5000, 250,  500,  4.5, 2),
  (10000,1000, 1000, 9.0, 3);

insert into gifts(name, category, price_coins, diamond_value, is_full_screen, min_level, sort_order) values
  ('Rose',   'normal',   10,    7, false, 1, 1),
  ('Crown',  'premium', 5000, 3500, true,  1, 2),
  ('Sports Car','premium',20000,14000, true, 10, 3),
  ('Dragon', 'premium',50000,35000, true, 20, 4);

insert into target_tiers(tier_name, min_live_hours, min_live_days, min_diamonds, salary_bdt, sort_order) values
  ('Bronze',  30, 12,   500000,  5000, 1),
  ('Silver',  60, 18,  1500000, 15000, 2),
  ('Gold',   100, 22,  4000000, 40000, 3);
