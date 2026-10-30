-- =====================================================================
-- rdlive : 004  Follows, Blocks, 1-on-1 Chat (text + image), Media   (PostgreSQL 16)
-- Run AFTER schema.sql, 002 and 003:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 004_follows_chat.sql
--
-- Realtime: chat functions emit pg_notify('chat_events', <small json>) at COMMIT.
-- The payload carries IDS ONLY (pg_notify is limited to 8000 bytes); the Go worker
-- loads the full message and pushes it to the two participants' WebSockets.
--
-- Read receipts: conversation_participants.last_read_message_id per user.
--   a message is "read" when message.id <= the OTHER participant's last_read_message_id.
-- Delete-for-me: conversation_participants.cleared_before_id hides older messages for
--   that user only. The conversation reappears in the inbox when a new message arrives.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- FOLLOWS (Home "Follow" tab) and BLOCKS
-- ---------------------------------------------------------------------
create table follows (
  id          bigint generated always as identity unique,   -- keyset pagination cursor
  follower_id bigint not null references users(id) on delete cascade,
  followee_id bigint not null references users(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (follower_id, followee_id),
  check (follower_id <> followee_id)
);
create index follows_following_idx on follows (follower_id, id desc);   -- "who I follow"
create index follows_followers_idx on follows (followee_id, id desc);   -- "my followers"

-- denormalised counters (profile screens must not count(*) millions of rows)
create table follow_stats (
  user_id   bigint primary key references users(id) on delete cascade,
  followers int not null default 0 check (followers >= 0),
  following int not null default 0 check (following >= 0)
);

create or replace function follows_count_trg() returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    insert into follow_stats(user_id, followers) values (new.followee_id, 1)
      on conflict (user_id) do update set followers = follow_stats.followers + 1;
    insert into follow_stats(user_id, following) values (new.follower_id, 1)
      on conflict (user_id) do update set following = follow_stats.following + 1;
    return new;
  else
    update follow_stats set followers = greatest(0, followers - 1) where user_id = old.followee_id;
    update follow_stats set following = greatest(0, following - 1) where user_id = old.follower_id;
    return old;
  end if;
end $$;
create trigger follows_count after insert or delete on follows
  for each row execute function follows_count_trg();

create table user_blocks (
  blocker_id bigint not null references users(id) on delete cascade,
  blocked_id bigint not null references users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);
create index user_blocks_blocked_idx on user_blocks (blocked_id);

create or replace function _users_blocked(a bigint, b bigint) returns boolean language sql stable as $$
  select exists (select 1 from user_blocks
                  where (blocker_id = a and blocked_id = b) or (blocker_id = b and blocked_id = a))
$$;

-- true = newly followed, false = already following (idempotent)
create or replace function follow_user(p_follower bigint, p_target bigint) returns boolean
language plpgsql as $$
declare n int;
begin
  if p_follower = p_target then raise exception 'cannot follow yourself'; end if;
  if not exists (select 1 from users where id = p_target and status = 'active') then
    raise exception 'user not found';
  end if;
  if _users_blocked(p_follower, p_target) then raise exception 'blocked'; end if;
  insert into follows(follower_id, followee_id) values (p_follower, p_target) on conflict do nothing;
  get diagnostics n = row_count;
  return n = 1;
end $$;

create or replace function unfollow_user(p_follower bigint, p_target bigint) returns boolean
language plpgsql as $$
declare n int;
begin
  delete from follows where follower_id = p_follower and followee_id = p_target;
  get diagnostics n = row_count;
  return n = 1;
end $$;

-- Blocking also removes follows in both directions.
create or replace function block_user(p_blocker bigint, p_target bigint) returns void
language plpgsql as $$
begin
  if p_blocker = p_target then raise exception 'cannot block yourself'; end if;
  if not exists (select 1 from users where id = p_target) then raise exception 'user not found'; end if;
  insert into user_blocks(blocker_id, blocked_id) values (p_blocker, p_target) on conflict do nothing;
  delete from follows where (follower_id = p_blocker and followee_id = p_target)
                         or (follower_id = p_target  and followee_id = p_blocker);
end $$;

create or replace function unblock_user(p_blocker bigint, p_target bigint) returns boolean
language plpgsql as $$
declare n int;
begin
  delete from user_blocks where blocker_id = p_blocker and blocked_id = p_target;
  get diagnostics n = row_count;
  return n = 1;
end $$;

-- ---------------------------------------------------------------------
-- HOST ROLE SYNC
-- Approving a host (host_profiles.status = 'active') must also make users.role = 'host': the API
-- guards (/v1/host/...) and profile cards read users.role. Only 'user' <-> 'host' is touched, so a
-- coin_seller / agency_owner / staff role is never overwritten.
-- ---------------------------------------------------------------------
create or replace function host_profile_sync_role() returns trigger language plpgsql as $$
begin
  if new.status = 'active' then
    update users set role = 'host' where id = new.user_id and role = 'user';
  else
    update users set role = 'user' where id = new.user_id and role = 'host';
  end if;
  return new;
end $$;
create trigger host_profiles_sync_role after insert or update of status on host_profiles
  for each row execute function host_profile_sync_role();
update users u set role = 'host'
  from host_profiles h where h.user_id = u.id and h.status = 'active' and u.role = 'user';   -- backfill

-- ---------------------------------------------------------------------
-- MEDIA REFERENCES (the bytes live in S3/R2/local disk; the DB only holds the reference)
-- ---------------------------------------------------------------------
create type media_status as enum ('pending', 'ready', 'deleted');

create table media_assets (
  id          uuid primary key default gen_random_uuid(),
  owner_id    bigint not null references users(id),
  purpose     text not null default 'chat_image' check (purpose in ('chat_image')),
  storage     text not null check (storage in ('local', 's3')),
  storage_key text not null unique,                       -- e.g. chat/<uuid>.jpg
  mime        text not null check (mime in ('image/jpeg', 'image/png', 'image/webp', 'image/gif')),
  size_bytes  bigint not null check (size_bytes between 1 and 10485760),   -- hard cap 10 MB (Go enforces its own, lower, limit)
  width       int check (width  between 1 and 20000),
  height      int check (height between 1 and 20000),
  status      media_status not null default 'pending',
  created_at  timestamptz not null default now(),
  ready_at    timestamptz
);
create index media_owner_idx   on media_assets (owner_id, created_at desc);
create index media_pending_idx on media_assets (created_at) where status = 'pending';   -- cleanup job

-- Step 1 of an upload: reserve an id + storage key. Max 30 uploads / hour / user.
create or replace function media_create(
  p_owner bigint, p_mime text, p_size bigint, p_w int, p_h int, p_storage text
) returns table(id uuid, storage_key text) language plpgsql as $$
declare mid uuid := gen_random_uuid(); ext text;
begin
  if not exists (select 1 from users where users.id = p_owner and status = 'active') then
    raise exception 'forbidden: account not active';
  end if;
  ext := case p_mime when 'image/jpeg' then '.jpg' when 'image/png' then '.png'
                     when 'image/webp' then '.webp' when 'image/gif' then '.gif' end;
  if ext is null then raise exception 'unsupported media type'; end if;
  if (select count(*) from media_assets m
       where m.owner_id = p_owner and m.created_at > now() - interval '1 hour') >= 30 then
    raise exception 'rate limited';
  end if;
  insert into media_assets(id, owner_id, storage, storage_key, mime, size_bytes, width, height)
  values (mid, p_owner, p_storage, 'chat/' || mid::text || ext, p_mime, p_size, p_w, p_h);
  return query select mid, 'chat/' || mid::text || ext;
end $$;

-- Step 2: the bytes arrived (Go verified size/type). Idempotent.
create or replace function media_mark_ready(p_owner bigint, p_id uuid, p_actual_size bigint) returns void
language plpgsql as $$
declare m media_assets;
begin
  select * into m from media_assets where id = p_id for update;
  if not found or m.owner_id <> p_owner then raise exception 'media not found'; end if;
  if m.status = 'ready' then return; end if;
  if m.status <> 'pending' then raise exception 'media not found'; end if;
  if p_actual_size < 1 or p_actual_size > 10485760 then raise exception 'media too large'; end if;
  update media_assets set status = 'ready', size_bytes = p_actual_size, ready_at = now() where id = p_id;
end $$;

-- ---------------------------------------------------------------------
-- 1-ON-1 CONVERSATIONS
-- ---------------------------------------------------------------------
create table conversations (
  id         bigint generated always as identity primary key,
  user_lo    bigint not null references users(id),
  user_hi    bigint not null references users(id),
  created_at timestamptz not null default now(),
  check (user_lo < user_hi),
  unique (user_lo, user_hi)
);

create table conversation_participants (
  conversation_id      bigint not null references conversations(id) on delete cascade,
  user_id              bigint not null references users(id),
  last_message_id      bigint not null default 0,    -- newest message in the thread (for inbox order)
  last_read_message_id bigint not null default 0,    -- read receipt
  cleared_before_id    bigint not null default 0,    -- delete-for-me watermark
  unread_count         int    not null default 0 check (unread_count >= 0),
  muted                boolean not null default false,
  primary key (conversation_id, user_id)
);
-- inbox = newest conversations first, straight off this index
create index conv_part_inbox_idx on conversation_participants (user_id, last_message_id desc);

create type chat_msg_kind as enum ('text', 'image');

create table messages (
  id              bigint generated always as identity primary key,
  conversation_id bigint not null references conversations(id) on delete cascade,
  sender_id       bigint not null references users(id),
  kind            chat_msg_kind not null,
  body            text check (char_length(body) <= 2000),     -- text, or an image caption
  media_id        uuid references media_assets(id),
  client_msg_id   text check (char_length(client_msg_id) between 8 and 64),   -- retry de-duplication
  created_at      timestamptz not null default now(),
  check (
    (kind = 'text'  and media_id is null     and body is not null and char_length(btrim(body)) > 0) or
    (kind = 'image' and media_id is not null and (body is null or char_length(body) <= 500))
  )
);
create index messages_conv_idx   on messages (conversation_id, id desc);
create index messages_sender_idx on messages (sender_id, created_at desc);          -- rate limit
create unique index messages_dedupe_uq on messages (conversation_id, sender_id, client_msg_id) where client_msg_id is not null;
create unique index messages_media_uq  on messages (media_id) where media_id is not null;   -- one image = one message

-- messages are history: no UPDATE, and no direct DELETE (only the cascade from a deleted conversation)
create or replace function _messages_append_only() returns trigger language plpgsql as $$
begin raise exception 'messages are append-only'; end $$;
create trigger messages_no_delete before delete on messages
  for each row when (pg_trigger_depth() = 0) execute function _messages_append_only();
create trigger messages_no_update before update on messages        -- nothing edits a stored message
  for each row execute function _messages_append_only();

create or replace function _chat_notify(p_payload jsonb) returns void language sql as $$
  select pg_notify('chat_events', p_payload::text)
$$;

-- get or create the thread between two users (peer chosen by the 8-digit public id in Go)
create or replace function chat_open(p_user bigint, p_peer bigint) returns bigint
language plpgsql as $$
declare lo bigint := least(p_user, p_peer); hi bigint := greatest(p_user, p_peer); cid bigint;
begin
  if p_user = p_peer then raise exception 'cannot message yourself'; end if;
  if not exists (select 1 from users where id = p_user and status = 'active') then
    raise exception 'forbidden: account not active';
  end if;
  if not exists (select 1 from users where id = p_peer and status = 'active') then
    raise exception 'user not found';
  end if;
  if _users_blocked(p_user, p_peer) then raise exception 'blocked'; end if;

  select id into cid from conversations where user_lo = lo and user_hi = hi;
  if not found then
    insert into conversations(user_lo, user_hi) values (lo, hi)
      on conflict (user_lo, user_hi) do nothing returning id into cid;
    if cid is null then select id into cid from conversations where user_lo = lo and user_hi = hi; end if;
  end if;
  insert into conversation_participants(conversation_id, user_id) values (cid, lo), (cid, hi)
    on conflict do nothing;
  return cid;
end $$;

-- Send a text or image message. Returns the message id (a retry with the same client_msg_id returns the same id).
create or replace function chat_send(
  p_user bigint, p_conv bigint, p_kind chat_msg_kind, p_body text, p_media uuid, p_client_id text
) returns bigint language plpgsql as $$
declare c conversations; peer bigint; mid bigint; txt text; m media_assets;
begin
  -- Lock the thread: sends in ONE conversation run one at a time, so message ids become visible in
  -- id order (clients can safely catch up with ?after_id=) and last_message_id never moves backwards.
  select * into c from conversations where id = p_conv for update;
  if not found or p_user not in (c.user_lo, c.user_hi) then raise exception 'conversation not found'; end if;
  peer := case when p_user = c.user_lo then c.user_hi else c.user_lo end;

  if p_client_id is not null then                                  -- retry of an already stored message
    select id into mid from messages
     where conversation_id = p_conv and sender_id = p_user and client_msg_id = p_client_id;
    if found then return mid; end if;
  end if;

  if not exists (select 1 from users where id = p_user and status = 'active') then
    raise exception 'forbidden: account not active';
  end if;
  if not exists (select 1 from users where id = peer and status = 'active') then
    raise exception 'recipient not available';
  end if;
  if _users_blocked(p_user, peer) then raise exception 'blocked'; end if;

  if (select count(*) from messages where sender_id = p_user and created_at > now() - interval '1 minute') >= 30 then
    raise exception 'rate limited';
  end if;

  txt := nullif(btrim(p_body), '');
  if p_kind = 'text' then
    if txt is null then raise exception 'empty message'; end if;
    if char_length(txt) > 2000 then raise exception 'message too long'; end if;
    if p_media is not null then raise exception 'media not allowed on text'; end if;
  else
    if txt is not null and char_length(txt) > 500 then raise exception 'message too long'; end if;
    select * into m from media_assets where id = p_media for update;
    if not found or m.owner_id <> p_user then raise exception 'media not found'; end if;
    if m.status <> 'ready' then raise exception 'media not ready'; end if;
    if exists (select 1 from messages where media_id = p_media) then raise exception 'media already used'; end if;
  end if;

  begin
    insert into messages(conversation_id, sender_id, kind, body, media_id, client_msg_id)
    values (p_conv, p_user, p_kind, txt, case when p_kind = 'image' then p_media end, p_client_id)
    returning id into mid;
  exception when unique_violation then                             -- two retries racing
    select id into mid from messages
     where conversation_id = p_conv and sender_id = p_user and client_msg_id = p_client_id;
    if mid is null then raise exception 'media already used'; end if;
    return mid;
  end;

  update conversation_participants
     set last_message_id = greatest(last_message_id, mid), last_read_message_id = greatest(last_read_message_id, mid), unread_count = 0
   where conversation_id = p_conv and user_id = p_user;
  update conversation_participants
     set last_message_id = greatest(last_message_id, mid), unread_count = unread_count + 1
   where conversation_id = p_conv and user_id = peer;

  perform _chat_notify(jsonb_build_object('type', 'message', 'conversation_id', p_conv,
                                          'message_id', mid, 'users', jsonb_build_array(p_user, peer)));
  return mid;
end $$;

-- Mark everything up to p_up_to (default: newest) as read. Returns the new read watermark.
create or replace function chat_mark_read(p_user bigint, p_conv bigint, p_up_to bigint default null)
returns bigint language plpgsql as $$
declare cp conversation_participants; newest bigint; target bigint; peer bigint; c conversations;
begin
  select * into c from conversations where id = p_conv;
  if not found or p_user not in (c.user_lo, c.user_hi) then raise exception 'conversation not found'; end if;
  peer := case when p_user = c.user_lo then c.user_hi else c.user_lo end;

  select * into cp from conversation_participants where conversation_id = p_conv and user_id = p_user for update;
  select coalesce(max(id), 0) into newest from messages where conversation_id = p_conv;
  target := least(coalesce(p_up_to, newest), newest);
  if target <= cp.last_read_message_id then return cp.last_read_message_id; end if;

  update conversation_participants
     set last_read_message_id = target,
         unread_count = (select count(*) from messages
                          where conversation_id = p_conv and sender_id <> p_user and id > target)
   where conversation_id = p_conv and user_id = p_user;
  perform _chat_notify(jsonb_build_object('type', 'read', 'conversation_id', p_conv, 'reader_id', p_user,
                                          'up_to_message_id', target, 'users', jsonb_build_array(peer)));
  return target;
end $$;

-- Delete the conversation FOR ME (the other person keeps their copy).
create or replace function chat_clear(p_user bigint, p_conv bigint) returns void language plpgsql as $$
declare newest bigint;
begin
  if not exists (select 1 from conversation_participants where conversation_id = p_conv and user_id = p_user) then
    raise exception 'conversation not found';
  end if;
  select coalesce(max(id), 0) into newest from messages where conversation_id = p_conv;
  update conversation_participants
     set cleared_before_id = newest, unread_count = 0, last_read_message_id = greatest(last_read_message_id, newest)
   where conversation_id = p_conv and user_id = p_user;
end $$;

create or replace function chat_set_muted(p_user bigint, p_conv bigint, p_muted boolean) returns void
language plpgsql as $$
begin
  update conversation_participants set muted = p_muted where conversation_id = p_conv and user_id = p_user;
  if not found then raise exception 'conversation not found'; end if;
end $$;

-- A user may fetch an image if they sent it or take part in the conversation it belongs to.
create or replace function media_can_view(p_user bigint, p_media uuid) returns boolean
language sql stable as $$
  select exists (select 1 from media_assets where id = p_media and owner_id = p_user)
      or exists (select 1 from messages m join conversations c on c.id = m.conversation_id
                  where m.media_id = p_media and p_user in (c.user_lo, c.user_hi))
$$;

-- ---------------------------------------------------------------------
-- READ MODELS
-- ---------------------------------------------------------------------
-- Inbox row for ONE user (filter: where user_id = :me). Empty / cleared threads are hidden.
create or replace view v_chat_inbox as
select cp.user_id, cp.conversation_id, cp.unread_count, cp.muted, cp.last_message_id,
       peer.id as peer_id, peer.public_id as peer_public_id, peer.display_name as peer_name,
       peer.avatar_url as peer_avatar, peer.country_code as peer_country, peer.level as peer_level,
       lm.sender_id as last_sender_id, lm.kind as last_kind, lm.body as last_body, lm.created_at as last_at,
       pcp.last_read_message_id as peer_last_read_message_id
  from conversation_participants cp
  join conversations c on c.id = cp.conversation_id
  join users peer on peer.id = case when cp.user_id = c.user_lo then c.user_hi else c.user_lo end
  join conversation_participants pcp on pcp.conversation_id = cp.conversation_id and pcp.user_id = peer.id
  join messages lm on lm.id = cp.last_message_id
 where cp.last_message_id > cp.cleared_before_id;

create or replace view v_follow_counts as
select u.id as user_id, coalesce(s.followers, 0) as followers, coalesce(s.following, 0) as following
  from users u left join follow_stats s on s.user_id = u.id;

commit;

-- =====================================================================
-- GO ERROR MAPPING (message PREFIX) -> HTTP
--   blocked -> 403 | rate limited -> 429 | conversation not found -> 404 | message too long / empty message -> 400
--   media not found -> 404 | media not ready / media already used -> 409 | unsupported media type -> 415
--   recipient not available -> 409 | cannot message yourself / cannot follow yourself / cannot block yourself -> 400
--
-- OPERATIONS
--   * Orphan uploads: delete media_assets rows with status='pending' older than 24h (and their files).
--   * Chat history grows fast: partition `messages` by month once it passes ~100M rows.
-- =====================================================================
