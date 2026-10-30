-- =====================================================================
-- rdlive : 003  Coin Distribution & Reseller System   (PostgreSQL 16)
-- Run AFTER schema.sql and 002_rooms_pk_moderation.sql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 003_coin_distribution.sql
--
-- Hierarchy
--   Super Admin --mint--> Coin Seller --sell--> Agency Owner | Host | User
--   (users --gift--> hosts, handled by send_gift, unchanged in spirit)
--
-- Where the money lives (nothing duplicated):
--   wallets        = the "user_wallets" you asked for (one row per user, coins+diamonds,
--                    CHECK >= 0 so a balance can never go negative)
--   wallet_ledger  = append-only ledger, one immutable row per balance change
--   coin_transfers = NEW: one business record per mint / sale / reclaim
--                    (who, whom, how many, cash received, payment ref)
--   Views user_wallets and coin_transactions give the names from the spec.
--
-- Double-spend / discrepancy protection
--   1. Every movement goes through wallet_apply(): row lock + CHECK(coins>=0).
--   2. Wallets are locked in user_id order (no deadlock between A->B and B->A).
--   3. Idempotency: a retried request returns the SAME transfer; the same key with
--      different parameters is rejected ("idempotency key reused ...").
--   4. A seller's own row is locked first, so the daily limit cannot be raced.
--   5. Daily mint cap (coin_policy) limits the damage of a stolen admin account.
--   6. audit_wallet_integrity() / audit_transfers() / coin_supply_report() prove
--      that ledger == wallet and every transfer balances.
-- =====================================================================

-- New enum values must be committed before use, so they live outside the transaction.
alter type user_role add value if not exists 'coin_seller';
alter type tx_type   add value if not exists 'admin_mint';
alter type tx_type   add value if not exists 'admin_reclaim';
alter type tx_type   add value if not exists 'seller_transfer_out';
alter type tx_type   add value if not exists 'seller_transfer_in';

begin;

create type transfer_kind as enum ('mint','seller_sale','reclaim');

-- ---------------------------------------------------------------------
-- TABLES
-- ---------------------------------------------------------------------
create table coin_policy (
  id                 smallint primary key default 1 check (id = 1),     -- single row
  max_mint_per_call  bigint not null default 100000000 check (max_mint_per_call > 0),
  max_mint_per_day   bigint not null default 500000000 check (max_mint_per_day  > 0),
  updated_at         timestamptz not null default now()
);
insert into coin_policy default values;

create table coin_sellers (
  user_id           bigint primary key references users(id),
  display_code      text not null unique,                                -- e.g. SELLER-01
  status            text not null default 'active' check (status in ('active','suspended')),
  daily_limit_coins bigint not null default 5000000 check (daily_limit_coins > 0),
  per_transfer_max  bigint not null default 1000000 check (per_transfer_max  > 0),
  created_by        bigint references users(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create trigger coin_sellers_upd before update on coin_sellers
  for each row execute function set_updated_at();

create table coin_transfers (
  id              bigint generated always as identity primary key,
  kind            transfer_kind not null,
  from_user_id    bigint references users(id),        -- null for mint
  to_user_id      bigint references users(id),        -- null for reclaim (coins are burned)
  amount          bigint not null check (amount > 0),
  price_bdt       numeric(14,2) check (price_bdt >= 0),   -- cash the seller received (accounting only)
  payment_method  text,                                -- bkash / nagad / rocket / bank / cash
  payment_ref     text,                                -- e.g. bKash TrxID
  note            text,
  actor_id        bigint not null references users(id),   -- seller or super admin who did it
  idempotency_key text not null unique,
  request_hash    text not null,
  created_at      timestamptz not null default now(),
  check (
    (kind = 'mint'        and from_user_id is null     and to_user_id is not null) or
    (kind = 'seller_sale' and from_user_id is not null and to_user_id is not null and from_user_id <> to_user_id) or
    (kind = 'reclaim'     and from_user_id is not null and to_user_id is null)
  )
);
create index coin_transfers_from_idx on coin_transfers (from_user_id, id desc);
create index coin_transfers_to_idx   on coin_transfers (to_user_id,   id desc);
create index coin_transfers_actor_day on coin_transfers (actor_id, created_at) where kind = 'seller_sale';
create index coin_transfers_mint_day  on coin_transfers (created_at) where kind = 'mint';
-- the same bKash/Nagad TrxID can be used for only one sale by a seller
create unique index coin_transfers_payment_ref_uq
  on coin_transfers (actor_id, payment_method, payment_ref) where payment_ref is not null;

-- transfers are history: never edited, never deleted (corrections = a new reclaim/sale)
create trigger coin_transfers_immutable before update or delete on coin_transfers
  for each row execute function ledger_immutable();

create table coin_admin_log (
  id         bigint generated always as identity primary key,
  actor_id   bigint not null references users(id),
  action     text not null,
  target_id  bigint references users(id),
  detail     jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create trigger coin_admin_log_immutable before update or delete on coin_admin_log
  for each row execute function ledger_immutable();

-- ---------------------------------------------------------------------
-- HELPERS
-- ---------------------------------------------------------------------
-- "today" for limits = Bangladesh calendar day
create or replace function coin_day_start() returns timestamptz language sql stable as $$
  select date_trunc('day', now() at time zone 'Asia/Dhaka') at time zone 'Asia/Dhaka'
$$;

create or replace function _require_super_admin(p_user bigint) returns void language plpgsql stable as $$
begin
  if not exists (select 1 from users where id = p_user and role = 'super_admin' and status = 'active') then
    raise exception 'forbidden: super admin only';
  end if;
end $$;

-- lock two wallets in a fixed order so opposite transfers can never deadlock
create or replace function _lock_wallets(a bigint, b bigint) returns void language plpgsql as $$
begin
  perform 1 from wallets where user_id in (a, b) order by user_id for update;
end $$;

-- ---------------------------------------------------------------------
-- SUPER ADMIN: seller management
-- ---------------------------------------------------------------------
create or replace function admin_create_seller(
  p_admin bigint, p_user bigint, p_code text,
  p_daily_limit bigint default 5000000, p_per_transfer_max bigint default 1000000
) returns void language plpgsql as $$
declare u users;
begin
  perform _require_super_admin(p_admin);
  select * into u from users where id = p_user for update;
  if not found then raise exception 'user not found'; end if;
  if u.status <> 'active' then raise exception 'user not allowed'; end if;
  if u.role <> 'user' or exists (select 1 from host_profiles where user_id = p_user)
                      or exists (select 1 from agencies where owner_user_id = p_user) then
    raise exception 'user not allowed: must be a plain user (not host/agency/staff)';
  end if;
  begin
    insert into coin_sellers(user_id, display_code, daily_limit_coins, per_transfer_max, created_by)
    values (p_user, p_code, p_daily_limit, p_per_transfer_max, p_admin);
  exception when unique_violation then
    raise exception 'seller code already used';
  end;
  update users set role = 'coin_seller' where id = p_user;
  insert into coin_admin_log(actor_id, action, target_id, detail)
  values (p_admin, 'create_seller', p_user,
          jsonb_build_object('code', p_code, 'daily_limit', p_daily_limit, 'per_transfer_max', p_per_transfer_max));
end $$;

create or replace function admin_update_seller(
  p_admin bigint, p_seller bigint, p_status text default null,
  p_daily_limit bigint default null, p_per_transfer_max bigint default null
) returns void language plpgsql as $$
begin
  perform _require_super_admin(p_admin);
  update coin_sellers
     set status            = coalesce(p_status, status),
         daily_limit_coins = coalesce(p_daily_limit, daily_limit_coins),
         per_transfer_max  = coalesce(p_per_transfer_max, per_transfer_max)
   where user_id = p_seller;
  if not found then raise exception 'seller not found'; end if;
  insert into coin_admin_log(actor_id, action, target_id, detail)
  values (p_admin, 'update_seller', p_seller,
          jsonb_strip_nulls(jsonb_build_object('status', p_status, 'daily_limit', p_daily_limit,
                                               'per_transfer_max', p_per_transfer_max)));
end $$;

-- ---------------------------------------------------------------------
-- SUPER ADMIN: mint (Master -> Seller)
-- ---------------------------------------------------------------------
create or replace function admin_mint_coins(
  p_admin bigint, p_seller bigint, p_amount bigint, p_note text, p_idem text
) returns bigint language plpgsql as $$
declare s coin_sellers; pol coin_policy; ex coin_transfers; h text; tid bigint; minted_today bigint;
begin
  perform _require_super_admin(p_admin);
  if p_idem is null or length(p_idem) < 8 then raise exception 'idempotency key required'; end if;

  select * into s from coin_sellers where user_id = p_seller for update;
  if not found then raise exception 'seller not found'; end if;

  h := md5(concat_ws('|', 'mint', p_admin, p_seller, p_amount, coalesce(p_note, '')));
  select * into ex from coin_transfers where idempotency_key = p_idem;
  if found then
    if ex.request_hash <> h or ex.actor_id <> p_admin then
      raise exception 'idempotency key reused with different request';
    end if;
    return ex.id;
  end if;

  if s.status <> 'active' or not exists (select 1 from users where id = p_seller and role = 'coin_seller' and status = 'active') then
    raise exception 'seller not active';
  end if;

  select * into pol from coin_policy;
  if p_amount < 1 or p_amount > pol.max_mint_per_call then raise exception 'amount out of range'; end if;
  perform pg_advisory_xact_lock(hashtext('rdlive_coin_mint'));            -- serialise the daily cap check
  select coalesce(sum(amount), 0) into minted_today
    from coin_transfers where kind = 'mint' and created_at >= coin_day_start();
  if minted_today + p_amount > pol.max_mint_per_day then raise exception 'daily mint cap exceeded'; end if;

  perform _lock_wallets(p_seller, p_seller);
  insert into coin_transfers(kind, to_user_id, amount, note, actor_id, idempotency_key, request_hash)
  values ('mint', p_seller, p_amount, p_note, p_admin, p_idem, h) returning id into tid;
  perform wallet_apply(p_seller, 'coin', p_amount, 'admin_mint', 'coin_transfer', tid::text,
                       'ct:' || tid || ':in', jsonb_build_object('actor', p_admin));
  return tid;
end $$;

-- ---------------------------------------------------------------------
-- SUPER ADMIN: reclaim (take coins back from ANY wallet; coins are burned)
-- ---------------------------------------------------------------------
create or replace function admin_reclaim_coins(
  p_admin bigint, p_from bigint, p_amount bigint, p_reason text, p_idem text
) returns bigint language plpgsql as $$
declare ex coin_transfers; h text; tid bigint;
begin
  perform _require_super_admin(p_admin);
  if p_idem is null or length(p_idem) < 8 then raise exception 'idempotency key required'; end if;
  if p_reason is null or length(btrim(p_reason)) < 3 then raise exception 'reason required'; end if;
  if p_amount < 1 then raise exception 'amount out of range'; end if;

  perform 1 from coin_sellers where user_id = p_from for update;      -- same lock order as seller sales
  h := md5(concat_ws('|', 'reclaim', p_admin, p_from, p_amount, p_reason));
  select * into ex from coin_transfers where idempotency_key = p_idem;
  if found then
    if ex.request_hash <> h or ex.actor_id <> p_admin then
      raise exception 'idempotency key reused with different request';
    end if;
    return ex.id;
  end if;
  if not exists (select 1 from users where id = p_from) then raise exception 'user not found'; end if;

  perform _lock_wallets(p_from, p_from);
  insert into coin_transfers(kind, from_user_id, amount, note, actor_id, idempotency_key, request_hash)
  values ('reclaim', p_from, p_amount, p_reason, p_admin, p_idem, h) returning id into tid;
  perform wallet_apply(p_from, 'coin', -p_amount, 'admin_reclaim', 'coin_transfer', tid::text,
                       'ct:' || tid || ':out', jsonb_build_object('actor', p_admin));   -- raises "insufficient coin balance"
  return tid;
end $$;

-- ---------------------------------------------------------------------
-- COIN SELLER: sell (Seller -> Agency Owner | Host | User)
-- ---------------------------------------------------------------------
create or replace function seller_transfer_coins(
  p_seller bigint, p_to bigint, p_amount bigint,
  p_price_bdt numeric default null, p_pay_method text default null, p_pay_ref text default null,
  p_note text default null, p_idem text default null
) returns bigint language plpgsql as $$
declare s coin_sellers; rc record; ex coin_transfers; h text; tid bigint; sold bigint;
begin
  if p_idem is null or length(p_idem) < 8 then raise exception 'idempotency key required'; end if;

  -- 1) lock the seller row first: serialises this seller's sales (daily limit, idempotency)
  select * into s from coin_sellers where user_id = p_seller for update;
  if not found or s.status <> 'active'
     or not exists (select 1 from users where id = p_seller and role = 'coin_seller' and status = 'active') then
    raise exception 'forbidden: not an active coin seller';
  end if;

  -- 2) replay?
  h := md5(concat_ws('|', 'sale', p_seller, p_to, p_amount,
                     coalesce(p_price_bdt::numeric(14,2)::text, ''), coalesce(p_pay_method, ''), coalesce(p_pay_ref, '')));
  select * into ex from coin_transfers where idempotency_key = p_idem;
  if found then
    if ex.request_hash <> h or ex.actor_id <> p_seller then
      raise exception 'idempotency key reused with different request';
    end if;
    return ex.id;
  end if;

  -- 3) validation
  if p_to = p_seller then raise exception 'cannot transfer to yourself'; end if;
  select id, role, status into rc from users where id = p_to;
  if not found then raise exception 'recipient not found'; end if;
  if rc.status <> 'active' or rc.role not in ('user', 'host', 'agency_owner') then
    raise exception 'recipient not allowed';
  end if;
  if p_amount < 1 or p_amount > s.per_transfer_max then raise exception 'amount out of range'; end if;
  select coalesce(sum(amount), 0) into sold
    from coin_transfers where kind = 'seller_sale' and actor_id = p_seller and created_at >= coin_day_start();
  if sold + p_amount > s.daily_limit_coins then raise exception 'daily limit exceeded'; end if;

  -- 4) move the coins
  perform _lock_wallets(p_seller, p_to);
  begin
    insert into coin_transfers(kind, from_user_id, to_user_id, amount, price_bdt, payment_method, payment_ref,
                               note, actor_id, idempotency_key, request_hash)
    values ('seller_sale', p_seller, p_to, p_amount, p_price_bdt, p_pay_method, nullif(btrim(p_pay_ref), ''),
            p_note, p_seller, p_idem, h) returning id into tid;
  exception when unique_violation then
    raise exception 'duplicate payment reference';
  end;
  perform wallet_apply(p_seller, 'coin', -p_amount, 'seller_transfer_out', 'coin_transfer', tid::text,
                       'ct:' || tid || ':out', jsonb_build_object('to', p_to));   -- raises "insufficient coin balance"
  perform wallet_apply(p_to, 'coin', p_amount, 'seller_transfer_in', 'coin_transfer', tid::text,
                       'ct:' || tid || ':in', jsonb_build_object('from', p_seller));
  return tid;
end $$;

-- ---------------------------------------------------------------------
-- GIFTING: hardened send_gift (same signature; PK trigger untouched)
--  + wallets locked in id order (no deadlock between A->B and B->A gifts)
--  + room gifts require sender AND receiver to be in the room (bans/kicks respected)
--  + idempotency key cannot be replayed by someone else
--  + host_daily_stats.gift_count is now maintained
--  + a 'gift' realtime event with the host's running daily total
-- ---------------------------------------------------------------------
create or replace function send_gift(
  p_sender bigint, p_receiver bigint, p_room bigint, p_gift int, p_qty int, p_idem text
) returns bigint language plpgsql as $$
declare g gifts%rowtype; cost bigint; earn bigint; gid bigint; lvl smallint; lv smallint;
        prev gift_transactions; today_diamonds bigint;
begin
  select * into prev from gift_transactions where idempotency_key = p_idem;
  if found then
    if prev.sender_id <> p_sender then raise exception 'idempotency key reused with different request'; end if;
    return prev.id;
  end if;

  if p_qty is null or p_qty < 1 then raise exception 'invalid quantity'; end if;
  if p_sender = p_receiver then raise exception 'cannot gift yourself'; end if;
  if not exists (select 1 from users where id = p_sender and status = 'active') then
    raise exception 'forbidden: account not active';
  end if;
  select * into g from gifts where id = p_gift and is_active;
  if not found then raise exception 'gift not available'; end if;
  select level into lv from users where id = p_sender;
  if lv < g.min_level then raise exception 'level too low for this gift'; end if;

  if p_room is not null then
    perform _room_get_live(p_room);
    if _room_member_role(p_room, p_sender) is null then raise exception 'not in room'; end if;
    if _room_member_role(p_room, p_receiver) is null then raise exception 'receiver not in room'; end if;
  end if;

  cost := g.price_coins   * p_qty;
  earn := g.diamond_value * p_qty;

  perform _lock_wallets(p_sender, p_receiver);

  insert into gift_transactions(sender_id,receiver_id,room_id,gift_id,quantity,coins_spent,diamonds_earned,idempotency_key)
  values (p_sender,p_receiver,p_room,p_gift,p_qty,cost,earn,p_idem) returning id into gid;   -- fires PK scoring trigger

  perform wallet_apply(p_sender,  'coin',    -cost,'gift_sent',    'gift_tx',gid::text,p_idem||':c');
  perform wallet_apply(p_receiver,'diamond',  earn,'gift_received','gift_tx',gid::text,p_idem||':d');

  update users set total_gifted_coins = total_gifted_coins + cost, xp = xp + cost where id = p_sender;
  select max(lc.level) into lvl from level_configs lc, users u where u.id = p_sender and lc.required_xp <= u.xp;
  update users set level = coalesce(lvl,1) where id = p_sender and level <> coalesce(lvl,1);

  insert into host_daily_stats(host_id, stat_date, diamonds_earned, gift_count)
  values (p_receiver, current_date, earn, p_qty)
  on conflict (host_id, stat_date) do update
     set diamonds_earned = host_daily_stats.diamonds_earned + earn,
         gift_count      = host_daily_stats.gift_count + p_qty
  returning diamonds_earned into today_diamonds;

  if p_room is not null then
    perform _room_notify(p_room, 'gift', jsonb_build_object(
      'gift_tx_id', gid, 'sender_id', p_sender, 'receiver_id', p_receiver, 'gift_id', p_gift,
      'quantity', p_qty, 'coins_spent', cost, 'diamonds_earned', earn, 'receiver_today_diamonds', today_diamonds));
  end if;
  return gid;
end $$;

-- ---------------------------------------------------------------------
-- VIEWS  (names from the spec + portal read models)
-- ---------------------------------------------------------------------
create or replace view user_wallets as
select w.user_id, u.public_id, u.display_name, u.role, u.status as account_status,
       w.coins, w.diamonds, w.updated_at
  from wallets w join users u on u.id = w.user_id;

create or replace view coin_transactions as
select l.id, l.user_id, l.amount, l.balance_after, l.tx_type, l.ref_type, l.ref_id, l.created_at,
       t.id as transfer_id, t.kind as transfer_kind,
       case when t.id is null then null when l.amount < 0 then t.to_user_id else t.from_user_id end as counterparty_id,
       t.price_bdt, t.payment_method, t.payment_ref, t.note
  from wallet_ledger l
  left join coin_transfers t
         on t.id = (case when l.ref_type = 'coin_transfer' then l.ref_id::bigint end)
 where l.asset = 'coin';

create or replace view v_coin_transfers as
select t.id, t.kind, t.amount, t.price_bdt, t.payment_method, t.payment_ref, t.note, t.created_at,
       t.from_user_id, fu.public_id as from_public_id, fu.display_name as from_name,
       t.to_user_id,   tu.public_id as to_public_id,   tu.display_name as to_name, tu.role as to_role,
       t.actor_id
  from coin_transfers t
  left join users fu on fu.id = t.from_user_id
  left join users tu on tu.id = t.to_user_id;

create or replace view v_seller_overview as
select s.user_id, u.public_id, u.display_name, s.display_code, s.status,
       s.daily_limit_coins, s.per_transfer_max, w.coins as balance,
       coalesce(d.sold_today, 0)::bigint                                    as sold_today,
       greatest(0, s.daily_limit_coins - coalesce(d.sold_today, 0))::bigint as remaining_today,
       coalesce(t.received_total, 0)::bigint as received_total,
       coalesce(t.sold_total, 0)::bigint     as sold_total,
       coalesce(t.revenue_bdt, 0)::numeric(14,2) as revenue_bdt
  from coin_sellers s
  join users u   on u.id = s.user_id
  join wallets w on w.user_id = s.user_id
  left join lateral (
    select sum(amount) as sold_today from coin_transfers
     where kind = 'seller_sale' and actor_id = s.user_id and created_at >= coin_day_start()) d on true
  left join lateral (
    select sum(amount) filter (where kind = 'mint' and to_user_id = s.user_id)          as received_total,
           sum(amount) filter (where kind = 'seller_sale' and from_user_id = s.user_id) as sold_total,
           sum(price_bdt) filter (where kind = 'seller_sale' and from_user_id = s.user_id) as revenue_bdt
      from coin_transfers where to_user_id = s.user_id or from_user_id = s.user_id) t on true;

-- ---------------------------------------------------------------------
-- AUDIT (run from the admin portal / a nightly job; empty result = healthy)
-- ---------------------------------------------------------------------
-- wallet balance must equal the sum of its ledger and the last balance_after
create or replace function audit_wallet_integrity()
returns table(user_id bigint, asset asset_type, wallet_balance bigint, ledger_sum bigint, last_balance_after bigint)
language sql stable as $$
  select w.user_id, a.asset, a.bal, coalesce(l.s, 0)::bigint, lb.balance_after
    from wallets w
    cross join lateral (values ('coin'::asset_type, w.coins), ('diamond'::asset_type, w.diamonds)) a(asset, bal)
    left join lateral (select sum(amount) s from wallet_ledger x where x.user_id = w.user_id and x.asset = a.asset) l on true
    left join lateral (select balance_after from wallet_ledger x where x.user_id = w.user_id and x.asset = a.asset
                        order by id desc limit 1) lb on true
   where a.bal <> coalesce(l.s, 0)
      or a.bal <> coalesce(lb.balance_after, 0)
$$;

-- every transfer must have exactly the ledger legs it claims
create or replace function audit_transfers()
returns table(transfer_id bigint, kind transfer_kind, amount bigint, legs bigint, net bigint)
language sql stable as $$
  select t.id, t.kind, t.amount, count(l.id)::bigint, coalesce(sum(l.amount), 0)::bigint
    from coin_transfers t
    left join wallet_ledger l on l.ref_type = 'coin_transfer' and l.ref_id = t.id::text
   group by t.id
  having not (
       (t.kind = 'mint'        and count(l.id) = 1 and coalesce(sum(l.amount), 0) =  t.amount)
    or (t.kind = 'reclaim'     and count(l.id) = 1 and coalesce(sum(l.amount), 0) = -t.amount)
    or (t.kind = 'seller_sale' and count(l.id) = 2 and coalesce(sum(l.amount), 0) =  0
                               and min(l.amount) = -t.amount)
  )
$$;

-- where all coins are right now, and where they came from
create or replace function coin_supply_report() returns jsonb language sql stable as $$
  select jsonb_build_object(
    'coins_in_wallets',      (select coalesce(sum(coins), 0) from wallets),
    'held_by_sellers',       (select coalesce(sum(w.coins), 0) from wallets w join users u on u.id = w.user_id where u.role = 'coin_seller'),
    'held_by_agency_owners', (select coalesce(sum(w.coins), 0) from wallets w join users u on u.id = w.user_id where u.role = 'agency_owner'),
    'held_by_hosts',         (select coalesce(sum(w.coins), 0) from wallets w join users u on u.id = w.user_id where u.role = 'host'),
    'held_by_users',         (select coalesce(sum(w.coins), 0) from wallets w join users u on u.id = w.user_id where u.role = 'user'),
    'minted_total',          (select coalesce(sum(amount), 0) from coin_transfers where kind = 'mint'),
    'sold_by_sellers_total', (select coalesce(sum(amount), 0) from coin_transfers where kind = 'seller_sale'),
    'reclaimed_total',       (select coalesce(sum(amount), 0) from coin_transfers where kind = 'reclaim'),
    'recharged_online',      (select coalesce(sum(amount), 0) from wallet_ledger where asset = 'coin' and tx_type = 'recharge'),
    'spent_on_gifts',        (select coalesce(-sum(amount), 0) from wallet_ledger where asset = 'coin' and tx_type = 'gift_sent'),
    'ledger_coin_net',       (select coalesce(sum(amount), 0) from wallet_ledger where asset = 'coin'),
    'wallet_integrity_issues', (select count(*) from audit_wallet_integrity()),
    'transfer_issues',         (select count(*) from audit_transfers())
  )
$$;

commit;

-- =====================================================================
-- GO ERROR MAPPING (match on the exception message PREFIX)
--   forbidden:*                          -> 403
--   idempotency key required             -> 400   idempotency key reused*  -> 409
--   amount out of range / reason required/ invalid quantity               -> 400
--   cannot transfer to yourself          -> 400
--   recipient not found / user not found / seller not found / recipient   -> 404
--   recipient not allowed / user not allowed*                             -> 422
--   seller not active                    -> 409
--   daily limit exceeded / daily mint cap exceeded                        -> 429
--   insufficient coin balance            -> 402
--   duplicate payment reference / seller code already used               -> 409
--   not in room / receiver not in room   -> 403   room not live           -> 410
--   SQLSTATE 40P01 (deadlock) / 40001 (serialization)  -> retry once
--
-- FIRST SUPER ADMIN (run once by hand, there is intentionally no API for it):
--   update users set role = 'super_admin' where public_id = <your public id>;
-- =====================================================================
