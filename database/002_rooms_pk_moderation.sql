-- =====================================================================
-- rdlive : 002  Rooms, Seats, PK Battle, Moderation   (PostgreSQL 16)
-- Run AFTER schema.sql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 002_rooms_pk_moderation.sql
--
-- Design rules
--  * All state changes go through the functions below. Each one re-checks
--    permissions itself (role rank), so a Go bug cannot bypass moderation.
--  * Functions raise exceptions whose message STARTS with a stable prefix.
--    The Go layer maps the prefix to an HTTP status (table at the bottom).
--  * Every mutation emits pg_notify('room_events', {...}) at COMMIT.
--    Go: LISTEN room_events -> push to clients (this replaces/feeds
--    realtime.Publisher).
--  * Reads for the Flutter screens come from the v_* views.
--
-- Flutter <-> schema mapping
--   RoomController.seats             -> v_room_seats
--   RoomController.requests          -> v_room_seat_requests
--   RoomController.participants      -> v_room_members
--   RoomController.banned            -> v_room_banned
--   LiveRoom (Home grid)             -> v_live_rooms_feed
--   PkController state               -> v_pk_battle_state
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- ENUMS
-- ---------------------------------------------------------------------
create type room_role        as enum ('audience','moderator','host');
create type room_media_mode  as enum ('audio','video');
create type seat_state       as enum ('empty','occupied','locked');
create type seat_req_status  as enum ('pending','approved','rejected','cancelled','expired');
create type room_action      as enum (
  'join','leave','mute','unmute','kick','ban','unban','remove_from_seat',
  'lock_seat','unlock_seat','approve_request','reject_request','set_role',
  'change_layout','pk_start','pk_end');
create type pk_status        as enum ('ready','running','finished','cancelled');
create type pk_side          as enum ('a','b');   -- a = red, b = blue

-- ---------------------------------------------------------------------
-- ROOMS (extends live_rooms from schema.sql)
-- ---------------------------------------------------------------------
alter table live_rooms
  add column media_mode           room_media_mode not null default 'audio',
  add column require_approval     boolean not null default true,
  add column viewer_count         int     not null default 0 check (viewer_count >= 0),
  add column cover_url            text,
  add column is_password_protected boolean generated always as (password_hash is not null) stored,
  add column updated_at           timestamptz not null default now();

create trigger live_rooms_upd before update on live_rooms
  for each row execute function set_updated_at();

-- one live room per host at a time
create unique index live_rooms_one_live_per_host on live_rooms (host_id) where status = 'live';
-- Home "Discover" feed
create index live_rooms_feed_idx on live_rooms (viewer_count desc, started_at desc) where status = 'live';

-- moderators a host appointed once; they are moderators in every future room
create table host_moderators (
  host_id    bigint not null references users(id) on delete cascade,
  user_id    bigint not null references users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (host_id, user_id),
  check (host_id <> user_id)
);

-- everyone currently (or previously) in a room
create table room_members (
  room_id   bigint not null references live_rooms(id) on delete cascade,
  user_id   bigint not null references users(id),
  role      room_role not null default 'audience',
  is_muted  boolean not null default false,       -- muted by staff for the whole room
  muted_by  bigint references users(id),
  joined_at timestamptz not null default now(),
  left_at   timestamptz,                          -- null = still in the room
  primary key (room_id, user_id)
);
create index room_members_active_idx on room_members (room_id, joined_at desc) where left_at is null;
create index room_members_user_idx   on room_members (user_id);

-- one row per seat; seat 0 is always the host seat
create table room_seats (
  room_id    bigint   not null references live_rooms(id) on delete cascade,
  seat_index smallint not null check (seat_index between 0 and 11),
  state      seat_state not null default 'empty',
  user_id    bigint references users(id),
  mic_on     boolean not null default true,       -- the occupant's own mic switch
  camera_on  boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (room_id, seat_index),
  check ((state = 'occupied') = (user_id is not null)),
  check (seat_index > 0 or state = 'occupied')    -- host seat is never empty/locked
);
-- a user can hold at most one seat per room
create unique index room_seats_user_uq on room_seats (room_id, user_id) where user_id is not null;

create table seat_requests (
  id          bigint generated always as identity primary key,
  room_id     bigint not null references live_rooms(id) on delete cascade,
  user_id     bigint not null references users(id),
  seat_index  smallint,                           -- preferred seat, null = any
  status      seat_req_status not null default 'pending',
  created_at  timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by bigint references users(id)
);
create unique index seat_requests_one_pending on seat_requests (room_id, user_id) where status = 'pending';
create index seat_requests_pending_idx on seat_requests (room_id, created_at) where status = 'pending';

-- Room ban is scoped to the HOST, so it survives into the host's next live session.
create table room_bans (
  id        bigint generated always as identity primary key,
  host_id   bigint not null references users(id),
  user_id   bigint not null references users(id),
  room_id   bigint references live_rooms(id) on delete set null,   -- room where it happened
  banned_by bigint not null references users(id),
  reason    text,
  created_at timestamptz not null default now(),
  lifted_at timestamptz,
  lifted_by bigint references users(id),
  check (host_id <> user_id)
);
create unique index room_bans_active_uq on room_bans (host_id, user_id) where lifted_at is null;

-- audit trail of every staff action (append-only)
create table room_moderation_log (
  id         bigint generated always as identity primary key,
  room_id    bigint not null references live_rooms(id) on delete cascade,
  actor_id   bigint references users(id),
  target_id  bigint references users(id),
  action     room_action not null,
  detail     jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index room_mod_log_idx on room_moderation_log (room_id, created_at desc);
create trigger room_mod_log_immutable before update or delete on room_moderation_log
  for each row execute function ledger_immutable();

-- ---------------------------------------------------------------------
-- PK BATTLES
-- ---------------------------------------------------------------------
create table pk_battles (
  id               bigint generated always as identity primary key,
  room_a           bigint not null references live_rooms(id),
  room_b           bigint not null references live_rooms(id),
  host_a           bigint not null references users(id),   -- red
  host_b           bigint not null references users(id),   -- blue
  duration_seconds int    not null default 300 check (duration_seconds between 30 and 3600),
  status           pk_status not null default 'ready',
  score_a          bigint not null default 0 check (score_a >= 0),
  score_b          bigint not null default 0 check (score_b >= 0),
  winner           pk_side,                                -- null on draw / unfinished
  is_draw          boolean not null default false,
  created_at       timestamptz not null default now(),
  started_at       timestamptz,
  ends_at          timestamptz,
  finished_at      timestamptz,
  check (host_a <> host_b),
  check (room_a <> room_b),
  check (status <> 'running' or (started_at is not null and ends_at is not null)),
  check (winner is null or status = 'finished')
);
create index pk_battles_running_idx on pk_battles (ends_at) where status = 'running';
create index pk_battles_host_a_idx  on pk_battles (host_a) where status in ('ready','running');
create index pk_battles_host_b_idx  on pk_battles (host_b) where status in ('ready','running');

-- every gift that counted, exactly once
create table pk_gift_scores (
  id         bigint generated always as identity primary key,
  battle_id  bigint not null references pk_battles(id) on delete cascade,
  side       pk_side not null,
  gift_tx_id bigint not null unique references gift_transactions(id),
  sender_id  bigint not null references users(id),
  points     bigint not null check (points > 0),
  created_at timestamptz not null default now()
);
create index pk_gift_scores_battle_idx on pk_gift_scores (battle_id, created_at);

-- =====================================================================
-- INTERNAL HELPERS
-- =====================================================================
create or replace function room_role_rank(r room_role) returns int
language sql immutable as $$
  select case r when 'host' then 3 when 'moderator' then 2 else 1 end
$$;

create or replace function _room_notify(p_room bigint, p_type text, p_data jsonb default '{}'::jsonb)
returns void language plpgsql as $$
begin
  perform pg_notify('room_events',
    jsonb_build_object('room_id', p_room, 'type', p_type, 'data', p_data)::text);
end $$;

create or replace function _room_log(p_room bigint, p_actor bigint, p_target bigint,
                                     p_action room_action, p_detail jsonb default '{}'::jsonb)
returns void language sql as $$
  insert into room_moderation_log(room_id, actor_id, target_id, action, detail)
  values (p_room, p_actor, p_target, p_action, p_detail)
$$;

create or replace function _room_get_live(p_room bigint) returns live_rooms
language plpgsql as $$
declare r live_rooms;
begin
  select * into r from live_rooms where id = p_room;
  if not found then raise exception 'room not found'; end if;
  if r.status <> 'live' then raise exception 'room not live'; end if;
  return r;
end $$;

create or replace function _room_member_role(p_room bigint, p_user bigint) returns room_role
language sql stable as $$
  select role from room_members where room_id = p_room and user_id = p_user and left_at is null
$$;

create or replace function _room_require_staff(p_room bigint, p_actor bigint) returns room_role
language plpgsql stable as $$
declare v room_role;
begin
  v := _room_member_role(p_room, p_actor);
  if v is null or v = 'audience' then
    raise exception 'forbidden: only the host or moderators can do this';
  end if;
  return v;
end $$;

-- actor must be staff and strictly outrank an active target (never themselves)
create or replace function _room_require_outrank(p_room bigint, p_actor bigint, p_target bigint)
returns void language plpgsql stable as $$
declare a room_role; t room_role;
begin
  a := _room_require_staff(p_room, p_actor);
  if p_actor = p_target then raise exception 'forbidden: cannot do this to yourself'; end if;
  t := _room_member_role(p_room, p_target);
  if t is null then raise exception 'target not in room'; end if;
  if room_role_rank(a) <= room_role_rank(t) then
    raise exception 'forbidden: insufficient rank';
  end if;
end $$;

create or replace function _room_refresh_viewers(p_room bigint) returns void
language sql as $$
  update live_rooms
     set viewer_count = (select count(*) from room_members where room_id = p_room and left_at is null)
   where id = p_room
$$;

create or replace function _room_free_seat(p_room bigint, p_user bigint) returns void
language sql as $$
  update room_seats
     set state = 'empty', user_id = null, mic_on = true, camera_on = false, updated_at = now()
   where room_id = p_room and user_id = p_user and seat_index > 0
$$;

create or replace function _room_first_free_seat(p_room bigint) returns int
language sql stable as $$
  select min(seat_index)::int from room_seats where room_id = p_room and state = 'empty'
$$;

create or replace function _seat_occupy(p_room bigint, p_seat int, p_user bigint) returns void
language plpgsql as $$
begin
  update room_seats
     set state = 'occupied', user_id = p_user, mic_on = true, camera_on = false, updated_at = now()
   where room_id = p_room and seat_index = p_seat and state = 'empty';
  if not found then raise exception 'seat taken'; end if;
end $$;

-- removes a user from the room: seat, pending requests, membership
create or replace function _room_remove_member(p_room bigint, p_target bigint) returns void
language plpgsql as $$
begin
  perform _room_free_seat(p_room, p_target);
  update seat_requests set status = 'cancelled', resolved_at = now()
   where room_id = p_room and user_id = p_target and status = 'pending';
  update room_members set left_at = now() where room_id = p_room and user_id = p_target and left_at is null;
  perform _room_refresh_viewers(p_room);
end $$;

-- =====================================================================
-- ROOM LIFECYCLE
-- =====================================================================

-- Creates the room, all seats (seat 0 = host), host membership and a live session.
create or replace function room_create(
  p_host bigint, p_title text default null, p_seat_count int default 8,
  p_media room_media_mode default 'audio', p_password_hash text default null,
  p_require_approval boolean default true
) returns bigint language plpgsql as $$
declare rid bigint;
begin
  if not exists (select 1 from users where id = p_host and status = 'active') then
    raise exception 'forbidden: account not active';
  end if;
  if not exists (select 1 from host_profiles where user_id = p_host and status = 'active') then
    raise exception 'forbidden: not an approved host';
  end if;
  begin
    insert into live_rooms(host_id, title, seat_count, media_mode, password_hash, require_approval, agora_channel)
    values (p_host, p_title, p_seat_count, p_media, p_password_hash, p_require_approval,
            'rd_' || replace(gen_random_uuid()::text, '-', ''))
    returning id into rid;
  exception when unique_violation then
    raise exception 'room already live';
  end;

  insert into room_seats(room_id, seat_index, state, user_id, mic_on, camera_on)
  select rid, g,
         (case when g = 0 then 'occupied' else 'empty' end)::seat_state,
         case when g = 0 then p_host end,
         true,
         (g = 0 and p_media = 'video')
    from generate_series(0, p_seat_count - 1) g;

  insert into room_members(room_id, user_id, role) values (rid, p_host, 'host');
  insert into host_live_sessions(host_id, room_id, started_at) values (p_host, rid, now());
  perform _room_refresh_viewers(rid);
  return rid;
end $$;

-- Host (or an admin) ends the room. Credits live seconds to host_daily_stats.
create or replace function room_end(p_room bigint, p_actor bigint) returns void
language plpgsql as $$
declare r live_rooms; secs int;
begin
  r := _room_get_live(p_room);
  if r.host_id <> p_actor
     and not exists (select 1 from users where id = p_actor and role in ('admin','super_admin','moderator')) then
    raise exception 'forbidden: only the host can end the room';
  end if;

  update live_rooms set status = 'ended', ended_at = now(), viewer_count = 0 where id = p_room;
  update room_members set left_at = now() where room_id = p_room and left_at is null;
  update seat_requests set status = 'expired', resolved_at = now() where room_id = p_room and status = 'pending';
  update pk_battles set status = 'cancelled', finished_at = now()
   where status in ('ready','running') and (room_a = p_room or room_b = p_room);

  update host_live_sessions set ended_at = now()
   where room_id = p_room and ended_at is null
  returning seconds into secs;
  if secs is not null then
    insert into host_daily_stats(host_id, stat_date, live_seconds)
    values (r.host_id, current_date, secs)
    on conflict (host_id, stat_date)
    do update set live_seconds = host_daily_stats.live_seconds + excluded.live_seconds;
  end if;
  perform _room_notify(p_room, 'room_ended');
end $$;

-- Password check is done in Go (compare against live_rooms.password_hash) BEFORE calling this.
create or replace function room_join(p_room bigint, p_user bigint) returns room_role
language plpgsql as $$
declare r live_rooms; v_role room_role;
begin
  r := _room_get_live(p_room);
  if not exists (select 1 from users where id = p_user and status = 'active') then
    raise exception 'forbidden: account not active';
  end if;
  if exists (select 1 from room_bans where host_id = r.host_id and user_id = p_user and lifted_at is null) then
    raise exception 'banned from room';
  end if;
  v_role := case
    when p_user = r.host_id then 'host'
    when exists (select 1 from host_moderators where host_id = r.host_id and user_id = p_user) then 'moderator'
    else 'audience' end;

  insert into room_members(room_id, user_id, role) values (p_room, p_user, v_role)
  on conflict (room_id, user_id)
  do update set left_at = null, joined_at = now(), role = excluded.role;   -- is_muted is kept: no escaping a mute by rejoining

  perform _room_refresh_viewers(p_room);
  perform _room_notify(p_room, 'members_changed');
  return v_role;
end $$;

create or replace function room_leave(p_room bigint, p_user bigint) returns void
language plpgsql as $$
declare r live_rooms;
begin
  r := _room_get_live(p_room);
  if r.host_id = p_user then raise exception 'host must end the room'; end if;
  if _room_member_role(p_room, p_user) is null then return; end if;
  perform _room_remove_member(p_room, p_user);
  perform _room_notify(p_room, 'left', jsonb_build_object('user_id', p_user));   -- realtime: drop their subscription
  perform _room_notify(p_room, 'members_changed');
  perform _room_notify(p_room, 'seats_changed');
end $$;

-- =====================================================================
-- SEATS
-- =====================================================================

-- Audience: creates a pending request (or sits directly when approval is off).
-- Staff: sits directly.   Returns {"result":"seated","seat_index":n} | {"result":"pending","request_id":id}
create or replace function seat_request_create(p_room bigint, p_user bigint, p_seat int default null)
returns jsonb language plpgsql as $$
declare r live_rooms; v_role room_role; st seat_state; target int; rid bigint;
begin
  r := _room_get_live(p_room);
  v_role := _room_member_role(p_room, p_user);
  if v_role is null then raise exception 'not in room'; end if;
  if exists (select 1 from room_seats where room_id = p_room and user_id = p_user) then
    raise exception 'already seated';
  end if;
  if p_seat is not null then
    select state into st from room_seats where room_id = p_room and seat_index = p_seat;
    if not found then raise exception 'seat not found'; end if;
    if st = 'locked'   then raise exception 'seat locked'; end if;
    if st = 'occupied' then raise exception 'seat taken'; end if;
  end if;

  if v_role <> 'audience' or not r.require_approval then
    target := coalesce(p_seat, _room_first_free_seat(p_room));
    if target is null then raise exception 'no free seat'; end if;
    perform _seat_occupy(p_room, target, p_user);
    perform _room_notify(p_room, 'seats_changed');
    return jsonb_build_object('result', 'seated', 'seat_index', target);
  end if;

  begin
    insert into seat_requests(room_id, user_id, seat_index) values (p_room, p_user, p_seat)
    returning id into rid;
  exception when unique_violation then
    raise exception 'request already pending';
  end;
  perform _room_notify(p_room, 'requests_changed');
  return jsonb_build_object('result', 'pending', 'request_id', rid);
end $$;

create or replace function seat_request_cancel(p_room bigint, p_user bigint) returns void
language plpgsql as $$
begin
  update seat_requests set status = 'cancelled', resolved_at = now(), resolved_by = p_user
   where room_id = p_room and user_id = p_user and status = 'pending';
  if found then perform _room_notify(p_room, 'requests_changed'); end if;
end $$;

-- Staff approve/reject. Returns the seat index on approval, null otherwise.
create or replace function seat_request_resolve(
  p_room bigint, p_actor bigint, p_request bigint, p_approve boolean, p_seat int default null
) returns int language plpgsql as $$
declare req seat_requests; target int;
begin
  perform _room_get_live(p_room);
  perform _room_require_staff(p_room, p_actor);
  select * into req from seat_requests where id = p_request and room_id = p_room for update;
  if not found or req.status <> 'pending' then raise exception 'request not found'; end if;

  if not p_approve then
    update seat_requests set status = 'rejected', resolved_at = now(), resolved_by = p_actor where id = p_request;
    perform _room_log(p_room, p_actor, req.user_id, 'reject_request');
    perform _room_notify(p_room, 'requests_changed');
    return null;
  end if;

  if _room_member_role(p_room, req.user_id) is null then      -- requester already left
    update seat_requests set status = 'expired', resolved_at = now(), resolved_by = p_actor where id = p_request;
    perform _room_notify(p_room, 'requests_changed');
    return null;
  end if;
  if exists (select 1 from room_seats where room_id = p_room and user_id = req.user_id) then
    raise exception 'already seated';
  end if;

  target := coalesce(p_seat, req.seat_index);
  if target is null or not exists (
       select 1 from room_seats where room_id = p_room and seat_index = target and state = 'empty') then
    target := _room_first_free_seat(p_room);
  end if;
  if target is null then raise exception 'no free seat'; end if;

  perform _seat_occupy(p_room, target, req.user_id);
  update seat_requests set status = 'approved', resolved_at = now(), resolved_by = p_actor where id = p_request;
  perform _room_log(p_room, p_actor, req.user_id, 'approve_request', jsonb_build_object('seat_index', target));
  perform _room_notify(p_room, 'seats_changed');
  perform _room_notify(p_room, 'requests_changed');
  return target;
end $$;

create or replace function seat_leave(p_room bigint, p_user bigint) returns void
language plpgsql as $$
declare idx int;
begin
  perform _room_get_live(p_room);
  select seat_index into idx from room_seats where room_id = p_room and user_id = p_user;
  if not found then raise exception 'not seated'; end if;
  if idx = 0 then raise exception 'host seat cannot be left'; end if;
  perform _room_free_seat(p_room, p_user);
  perform _room_notify(p_room, 'seats_changed');
end $$;

-- Own mic / camera. A user muted by staff cannot switch the mic on.
create or replace function seat_set_media(p_room bigint, p_user bigint,
                                          p_mic boolean default null, p_camera boolean default null)
returns void language plpgsql as $$
begin
  perform _room_get_live(p_room);
  if not exists (select 1 from room_seats where room_id = p_room and user_id = p_user) then
    raise exception 'not seated';
  end if;
  if p_mic is true and coalesce(
       (select is_muted from room_members where room_id = p_room and user_id = p_user), false) then
    raise exception 'muted by host';
  end if;
  update room_seats
     set mic_on = coalesce(p_mic, mic_on), camera_on = coalesce(p_camera, camera_on), updated_at = now()
   where room_id = p_room and user_id = p_user;
  perform _room_notify(p_room, 'seats_changed');
end $$;

create or replace function seat_lock(p_room bigint, p_actor bigint, p_seat int) returns void
language plpgsql as $$
declare st seat_state;
begin
  perform _room_get_live(p_room);
  perform _room_require_staff(p_room, p_actor);
  if p_seat <= 0 then raise exception 'seat cannot be locked'; end if;
  select state into st from room_seats where room_id = p_room and seat_index = p_seat for update;
  if not found then raise exception 'seat not found'; end if;
  if st <> 'empty' then raise exception 'seat not empty'; end if;
  update room_seats set state = 'locked', updated_at = now() where room_id = p_room and seat_index = p_seat;
  update seat_requests set seat_index = null
   where room_id = p_room and status = 'pending' and seat_index = p_seat;
  perform _room_log(p_room, p_actor, null, 'lock_seat', jsonb_build_object('seat_index', p_seat));
  perform _room_notify(p_room, 'seats_changed');
end $$;

create or replace function seat_unlock(p_room bigint, p_actor bigint, p_seat int) returns void
language plpgsql as $$
begin
  perform _room_get_live(p_room);
  perform _room_require_staff(p_room, p_actor);
  update room_seats set state = 'empty', updated_at = now()
   where room_id = p_room and seat_index = p_seat and state = 'locked';
  if not found then raise exception 'seat not locked'; end if;
  perform _room_log(p_room, p_actor, null, 'unlock_seat', jsonb_build_object('seat_index', p_seat));
  perform _room_notify(p_room, 'seats_changed');
end $$;

create or replace function seat_remove_user(p_room bigint, p_actor bigint, p_target bigint) returns void
language plpgsql as $$
begin
  perform _room_get_live(p_room);
  perform _room_require_outrank(p_room, p_actor, p_target);
  if not exists (select 1 from room_seats where room_id = p_room and user_id = p_target) then
    raise exception 'target not seated';
  end if;
  perform _room_free_seat(p_room, p_target);
  perform _room_log(p_room, p_actor, p_target, 'remove_from_seat');
  perform _room_notify(p_room, 'seats_changed');
end $$;

-- Host only. Mirrors Flutter RoomController.setLayout: guests on removed seats move to a
-- free seat if one exists, otherwise they stay in the room unseated.
create or replace function room_set_layout(p_room bigint, p_actor bigint, p_seat_count int) returns void
language plpgsql as $$
declare r live_rooms; rec record; free_idx int;
begin
  r := _room_get_live(p_room);
  if _room_member_role(p_room, p_actor) is distinct from 'host' then
    raise exception 'forbidden: only the host can change the layout';
  end if;
  if p_seat_count = r.seat_count then return; end if;

  if p_seat_count > r.seat_count then
    insert into room_seats(room_id, seat_index)
    select p_room, g from generate_series(r.seat_count, p_seat_count - 1) g;
  else
    for rec in
      select seat_index, user_id, mic_on, camera_on from room_seats
       where room_id = p_room and seat_index >= p_seat_count and state = 'occupied'
       order by seat_index
    loop
      update room_seats set state = 'empty', user_id = null, mic_on = true, camera_on = false
       where room_id = p_room and seat_index = rec.seat_index;
      select min(seat_index) into free_idx from room_seats
       where room_id = p_room and seat_index < p_seat_count and state = 'empty';
      if free_idx is not null then
        update room_seats
           set state = 'occupied', user_id = rec.user_id, mic_on = rec.mic_on, camera_on = rec.camera_on,
               updated_at = now()
         where room_id = p_room and seat_index = free_idx;
      end if;
    end loop;
    delete from room_seats where room_id = p_room and seat_index >= p_seat_count;
    update seat_requests set seat_index = null
     where room_id = p_room and status = 'pending' and seat_index >= p_seat_count;
  end if;

  update live_rooms set seat_count = p_seat_count where id = p_room;   -- CHECK allows 4,6,8,9,12
  perform _room_log(p_room, p_actor, null, 'change_layout', jsonb_build_object('seat_count', p_seat_count));
  perform _room_notify(p_room, 'seats_changed');
  perform _room_notify(p_room, 'requests_changed');
end $$;

create or replace function room_set_require_approval(p_room bigint, p_actor bigint, p_value boolean) returns void
language plpgsql as $$
begin
  perform _room_get_live(p_room);
  if _room_member_role(p_room, p_actor) is distinct from 'host' then
    raise exception 'forbidden: only the host can change this';
  end if;
  update live_rooms set require_approval = p_value where id = p_room;
  perform _room_notify(p_room, 'room_settings_changed');
end $$;

-- =====================================================================
-- MODERATION  (staff only, strictly higher rank than the target)
-- =====================================================================

create or replace function room_mute_user(p_room bigint, p_actor bigint, p_target bigint, p_muted boolean)
returns void language plpgsql as $$
begin
  perform _room_get_live(p_room);
  perform _room_require_outrank(p_room, p_actor, p_target);
  update room_members
     set is_muted = p_muted, muted_by = case when p_muted then p_actor end
   where room_id = p_room and user_id = p_target and left_at is null;
  perform _room_log(p_room, p_actor, p_target, (case when p_muted then 'mute' else 'unmute' end)::room_action);
  perform _room_notify(p_room, 'members_changed');
  perform _room_notify(p_room, 'seats_changed');
end $$;

-- Removes the user from the room; they may rejoin.
create or replace function room_kick_user(p_room bigint, p_actor bigint, p_target bigint) returns void
language plpgsql as $$
begin
  perform _room_get_live(p_room);
  perform _room_require_outrank(p_room, p_actor, p_target);
  perform _room_remove_member(p_room, p_target);
  perform _room_log(p_room, p_actor, p_target, 'kick');
  perform _room_notify(p_room, 'kicked', jsonb_build_object('user_id', p_target, 'banned', false));
  perform _room_notify(p_room, 'members_changed');
  perform _room_notify(p_room, 'seats_changed');
end $$;

-- Kick + block from this host's rooms until unbanned.
create or replace function room_ban_user(p_room bigint, p_actor bigint, p_target bigint, p_reason text default null)
returns void language plpgsql as $$
declare r live_rooms;
begin
  r := _room_get_live(p_room);
  perform _room_require_outrank(p_room, p_actor, p_target);
  perform _room_remove_member(p_room, p_target);
  insert into room_bans(host_id, user_id, room_id, banned_by, reason)
  values (r.host_id, p_target, p_room, p_actor, p_reason)
  on conflict (host_id, user_id) where lifted_at is null do nothing;
  perform _room_log(p_room, p_actor, p_target, 'ban', jsonb_build_object('reason', p_reason));
  perform _room_notify(p_room, 'kicked', jsonb_build_object('user_id', p_target, 'banned', true));
  perform _room_notify(p_room, 'members_changed');
  perform _room_notify(p_room, 'seats_changed');
end $$;

create or replace function room_unban_user(p_room bigint, p_actor bigint, p_target bigint) returns void
language plpgsql as $$
declare r live_rooms;
begin
  r := _room_get_live(p_room);
  perform _room_require_staff(p_room, p_actor);
  update room_bans set lifted_at = now(), lifted_by = p_actor
   where host_id = r.host_id and user_id = p_target and lifted_at is null;
  if not found then raise exception 'ban not found'; end if;
  perform _room_log(p_room, p_actor, p_target, 'unban');
  perform _room_notify(p_room, 'bans_changed');
end $$;

-- Host appoints / removes a moderator (persisted in host_moderators).
create or replace function room_set_role(p_room bigint, p_actor bigint, p_target bigint, p_role room_role)
returns void language plpgsql as $$
declare r live_rooms;
begin
  r := _room_get_live(p_room);
  if _room_member_role(p_room, p_actor) is distinct from 'host' then
    raise exception 'forbidden: only the host can change roles';
  end if;
  if p_role = 'host' then raise exception 'invalid role'; end if;
  if p_target = r.host_id then raise exception 'forbidden: cannot change the host'; end if;
  if _room_member_role(p_room, p_target) is null then raise exception 'target not in room'; end if;

  update room_members set role = p_role where room_id = p_room and user_id = p_target;
  if p_role = 'moderator' then
    insert into host_moderators(host_id, user_id) values (r.host_id, p_target) on conflict do nothing;
  else
    delete from host_moderators where host_id = r.host_id and user_id = p_target;
  end if;
  perform _room_log(p_room, p_actor, p_target, 'set_role', jsonb_build_object('role', p_role));
  perform _room_notify(p_room, 'members_changed');
end $$;

-- =====================================================================
-- PK BATTLE
-- =====================================================================

-- Host of room A opens a battle against room B (status 'ready').
create or replace function pk_create(p_actor bigint, p_room_a bigint, p_room_b bigint, p_duration int default 300)
returns bigint language plpgsql as $$
declare ra live_rooms; rb live_rooms; bid bigint;
begin
  ra := _room_get_live(p_room_a);
  rb := _room_get_live(p_room_b);
  if ra.host_id <> p_actor then raise exception 'forbidden: only the room host can start a PK'; end if;
  if ra.host_id = rb.host_id then raise exception 'invalid opponent'; end if;

  -- serialise concurrent PK creation for these two hosts (always lock in id order)
  perform pg_advisory_xact_lock(least(ra.host_id, rb.host_id));
  perform pg_advisory_xact_lock(greatest(ra.host_id, rb.host_id));
  if exists (select 1 from pk_battles
              where status in ('ready','running')
                and (host_a in (ra.host_id, rb.host_id) or host_b in (ra.host_id, rb.host_id))) then
    raise exception 'host already in a PK';
  end if;

  insert into pk_battles(room_a, room_b, host_a, host_b, duration_seconds)
  values (p_room_a, p_room_b, ra.host_id, rb.host_id, p_duration)
  returning id into bid;
  perform _room_notify(p_room_a, 'pk_created', jsonb_build_object('battle_id', bid));
  perform _room_notify(p_room_b, 'pk_created', jsonb_build_object('battle_id', bid));
  return bid;
end $$;

create or replace function pk_start(p_battle bigint, p_actor bigint) returns void
language plpgsql as $$
declare b pk_battles;
begin
  select * into b from pk_battles where id = p_battle for update;
  if not found then raise exception 'battle not found'; end if;
  if p_actor not in (b.host_a, b.host_b) then raise exception 'forbidden: only the battling hosts can do this'; end if;
  if b.status <> 'ready' then raise exception 'pk not ready'; end if;
  update pk_battles
     set status = 'running', started_at = now(), ends_at = now() + make_interval(secs => b.duration_seconds)
   where id = p_battle;
  perform _room_log(b.room_a, p_actor, null, 'pk_start', jsonb_build_object('battle_id', p_battle));
  perform _room_log(b.room_b, p_actor, null, 'pk_start', jsonb_build_object('battle_id', p_battle));
  perform _room_notify(b.room_a, 'pk_started', jsonb_build_object('battle_id', p_battle));
  perform _room_notify(b.room_b, 'pk_started', jsonb_build_object('battle_id', p_battle));
end $$;

-- Finish a running battle. p_actor = a battling host (End PK button) or null (cron: only when time is up).
create or replace function pk_finish(p_battle bigint, p_actor bigint default null) returns void
language plpgsql as $$
declare b pk_battles; w pk_side; draw boolean;
begin
  select * into b from pk_battles where id = p_battle for update;
  if not found then raise exception 'battle not found'; end if;
  if b.status <> 'running' then return; end if;            -- idempotent
  if p_actor is not null then
    if p_actor not in (b.host_a, b.host_b) then raise exception 'forbidden: only the battling hosts can do this'; end if;
  elsif b.ends_at > now() then
    return;                                                 -- cron must not end early
  end if;

  draw := b.score_a = b.score_b;
  w := case when draw then null when b.score_a > b.score_b then 'a'::pk_side else 'b'::pk_side end;
  update pk_battles set status = 'finished', finished_at = now(), winner = w, is_draw = draw where id = p_battle;

  perform _room_log(b.room_a, p_actor, null, 'pk_end', jsonb_build_object('battle_id', p_battle));
  perform _room_log(b.room_b, p_actor, null, 'pk_end', jsonb_build_object('battle_id', p_battle));
  perform _room_notify(b.room_a, 'pk_finished',
    jsonb_build_object('battle_id', p_battle, 'winner', w, 'is_draw', draw, 'score_a', b.score_a, 'score_b', b.score_b));
  perform _room_notify(b.room_b, 'pk_finished',
    jsonb_build_object('battle_id', p_battle, 'winner', w, 'is_draw', draw, 'score_a', b.score_a, 'score_b', b.score_b));
end $$;

-- Call every few seconds from a Go ticker (or pg_cron). Returns how many battles were closed.
create or replace function pk_finish_due() returns int language plpgsql as $$
declare id bigint; n int := 0;
begin
  for id in select pb.id from pk_battles pb where pb.status = 'running' and pb.ends_at <= now() loop
    perform pk_finish(id, null);
    n := n + 1;
  end loop;
  return n;
end $$;

-- "Rematch" button: new battle between the same rooms, started immediately.
create or replace function pk_rematch(p_battle bigint, p_actor bigint) returns bigint
language plpgsql as $$
declare b pk_battles; nid bigint;
begin
  select * into b from pk_battles where id = p_battle;
  if not found then raise exception 'battle not found'; end if;
  if p_actor not in (b.host_a, b.host_b) then raise exception 'forbidden: only the battling hosts can do this'; end if;
  if b.status <> 'finished' then raise exception 'pk not finished'; end if;
  nid := pk_create(b.host_a, b.room_a, b.room_b, b.duration_seconds);   -- same sides (red/blue)
  perform pk_start(nid, p_actor);
  return nid;
end $$;

-- Every gift to a battling host while the battle is running counts for that side.
-- This is a trigger on gift_transactions, so send_gift() needs no change.
create or replace function pk_apply_gift() returns trigger language plpgsql as $$
declare b pk_battles; s pk_side;
begin
  select * into b from pk_battles
   where status = 'running' and ends_at > now()
     and (host_a = new.receiver_id or host_b = new.receiver_id)
   order by id desc limit 1
   for update;
  if not found then return new; end if;

  s := case when b.host_a = new.receiver_id then 'a'::pk_side else 'b'::pk_side end;
  insert into pk_gift_scores(battle_id, side, gift_tx_id, sender_id, points)
  values (b.id, s, new.id, new.sender_id, new.coins_spent)
  on conflict (gift_tx_id) do nothing;
  if not found then return new; end if;

  update pk_battles
     set score_a = score_a + case when s = 'a' then new.coins_spent else 0 end,
         score_b = score_b + case when s = 'b' then new.coins_spent else 0 end
   where id = b.id
  returning * into b;

  perform _room_notify(b.room_a, 'pk_score', jsonb_build_object(
    'battle_id', b.id, 'side', s, 'points', new.coins_spent, 'sender_id', new.sender_id,
    'score_a', b.score_a, 'score_b', b.score_b));
  perform _room_notify(b.room_b, 'pk_score', jsonb_build_object(
    'battle_id', b.id, 'side', s, 'points', new.coins_spent, 'sender_id', new.sender_id,
    'score_a', b.score_a, 'score_b', b.score_b));
  return new;
end $$;

create trigger gift_pk_score after insert on gift_transactions
  for each row execute function pk_apply_gift();

-- =====================================================================
-- READ MODELS FOR THE FLUTTER SCREENS
-- =====================================================================

-- Home grid (LiveRoom model): id, host_name, country_code, cover_url, badge, audience_avatars
create or replace view v_live_rooms_feed as
select r.id,
       r.title,
       u.display_name                              as host_name,
       u.country_code,
       coalesce(r.cover_url, u.avatar_url)         as cover_url,
       case when hp.approved_at > now() - interval '30 days' then 'New Star' end as badge,
       r.media_mode, r.seat_count, r.viewer_count, r.is_password_protected, r.started_at,
       coalesce((
         select array_agg(a.avatar_url)
           from (select u2.avatar_url
                   from room_members m join users u2 on u2.id = m.user_id
                  where m.room_id = r.id and m.left_at is null and m.user_id <> r.host_id
                    and u2.avatar_url is not null
                  order by m.joined_at desc limit 3) a
       ), '{}') as audience_avatars
  from live_rooms r
  join users u on u.id = r.host_id
  left join host_profiles hp on hp.user_id = r.host_id
 where r.status = 'live';

-- Seat grid (Seat model). mic_active = own switch ON and not muted by staff.
create or replace view v_room_seats as
select s.room_id, s.seat_index, s.state, s.user_id,
       u.display_name, u.avatar_url, u.country_code, u.level,
       m.role as user_role, coalesce(m.is_muted, false) as user_muted,
       s.mic_on,
       (s.state = 'occupied' and s.mic_on and not coalesce(m.is_muted, false)) as mic_active,
       s.camera_on
  from room_seats s
  left join users u on u.id = s.user_id
  left join room_members m on m.room_id = s.room_id and m.user_id = s.user_id;

-- Pending requests tab
create or replace view v_room_seat_requests as
select q.id, q.room_id, q.user_id, u.display_name, u.avatar_url, u.country_code, u.level,
       q.seat_index, q.created_at
  from seat_requests q join users u on u.id = q.user_id
 where q.status = 'pending';

-- People tab (active members + their seat)
create or replace view v_room_members as
select m.room_id, m.user_id, u.display_name, u.avatar_url, u.country_code, u.level,
       m.role, m.is_muted, m.joined_at, s.seat_index
  from room_members m
  join users u on u.id = m.user_id
  left join room_seats s on s.room_id = m.room_id and s.user_id = m.user_id
 where m.left_at is null;

-- Banned tab (bans are per host; join on the room's host)
create or replace view v_room_banned as
select r.id as room_id, b.user_id, u.display_name, u.avatar_url, u.country_code, u.level,
       b.reason, b.created_at
  from live_rooms r
  join room_bans b on b.host_id = r.host_id and b.lifted_at is null
  join users u on u.id = b.user_id;

-- PK overlay: scores, remaining time, clamped red share (same 0.08..0.92 clamp as Flutter)
create or replace view v_pk_battle_state as
select b.id, b.room_a, b.room_b, b.host_a, b.host_b, b.status, b.duration_seconds,
       b.score_a, b.score_b, b.winner, b.is_draw, b.started_at, b.ends_at, b.finished_at,
       case b.status
         when 'running' then greatest(0, ceil(extract(epoch from (b.ends_at - now())))::int)
         when 'ready'   then b.duration_seconds
         else 0 end as remaining_seconds,
       (case when b.score_a + b.score_b = 0 then 0.5
             else least(0.92::numeric, greatest(0.08::numeric, b.score_a::numeric / (b.score_a + b.score_b)))
        end)::float8 as ratio_a,
       ua.display_name as host_a_name, ua.country_code as host_a_country, ua.avatar_url as host_a_avatar,
       ub.display_name as host_b_name, ub.country_code as host_b_country, ub.avatar_url as host_b_avatar
  from pk_battles b
  join users ua on ua.id = b.host_a
  join users ub on ub.id = b.host_b;

commit;

-- =====================================================================
-- GO ERROR MAPPING (match on the exception message PREFIX)
--   forbidden:*                 -> 403        banned from room        -> 403
--   room not found / not found  -> 404        target not in room      -> 404
--   room not live               -> 410        request not found       -> 404
--   seat taken / seat locked /
--   already seated / seat not
--   empty / no free seat /
--   request already pending /
--   room already live /
--   host already in a PK /
--   pk not ready/not finished   -> 409        muted by host           -> 403
--   not in room / not seated    -> 409        host seat cannot be left-> 409
--   host must end the room      -> 409        invalid role/opponent   -> 400
--   SQLSTATE 23514 (check)      -> 400 (e.g. bad seat_count / duration)
--
-- ENDPOINT -> FUNCTION (suggested)
--   POST /v1/rooms                      room_create        (hash the password in Go)
--   POST /v1/rooms/{id}/end             room_end
--   POST /v1/rooms/{id}/join            room_join          (verify password first)
--   POST /v1/rooms/{id}/leave           room_leave
--   POST /v1/rooms/{id}/seats/request   seat_request_create
--   DELETE /v1/rooms/{id}/seats/request seat_request_cancel
--   POST /v1/rooms/{id}/requests/{rid}  seat_request_resolve (approve|reject)
--   POST /v1/rooms/{id}/seats/leave     seat_leave
--   PATCH /v1/rooms/{id}/seats/me       seat_set_media
--   POST /v1/rooms/{id}/seats/{n}/lock|unlock   seat_lock / seat_unlock
--   POST /v1/rooms/{id}/members/{uid}/mute|unmute|kick|ban|unban|remove-seat|role
--   PATCH /v1/rooms/{id}                room_set_layout / room_set_require_approval
--   POST /v1/pk  /v1/pk/{id}/start|finish|rematch      pk_create/pk_start/pk_finish/pk_rematch
--   ticker every 2-5s                   select pk_finish_due();
--   GET /v1/rooms?tab=discover          select * from v_live_rooms_feed order by viewer_count desc
--   ("Follow" tab needs a follows table: not part of this migration)
-- =====================================================================
