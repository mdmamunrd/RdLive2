-- =====================================================================
-- rdlive : 005  Media cleanup for chat images   (PostgreSQL 16)
-- Run AFTER 004_follows_chat.sql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 005_media_cleanup.sql
--
-- An upload is a 3-step flow (reserve -> upload -> attach to a message), and users abandon it
-- all the time (picked a photo, changed their mind, lost signal). Without cleanup those rows and
-- files pile up forever. The Go worker calls media_expire_unused() hourly and deletes the returned
-- objects from storage.
-- =====================================================================
begin;

-- "used" = attached to a message. A trigger keeps it current, so the cleanup scan below only ever sees
-- genuinely unused uploads (the vast majority of rows are sent images, which must never slow it down
-- or push real orphans out of the LIMIT window).
alter table media_assets add column used boolean not null default false;
update media_assets ma set used = true where exists (select 1 from messages m where m.media_id = ma.id);
create index media_unused_idx on media_assets (created_at) where not used and status in ('pending', 'ready');

create or replace function _media_mark_used() returns trigger language plpgsql as $$
begin
  update media_assets set used = true where id = new.media_id;
  return null;
end $$;
create trigger messages_mark_media_used after insert on messages
  for each row when (new.media_id is not null) execute function _media_mark_used();

-- Marks unused uploads older than p_older as 'deleted' and returns what the worker must remove
-- from storage. Safe to run on several API replicas at once.
create or replace function media_expire_unused(p_older interval default interval '24 hours', p_limit int default 200)
returns table(id uuid, storage text, storage_key text)
language plpgsql as $$
declare r record;
begin
  for r in
    select ma.id as mid from media_assets ma
     where not ma.used and ma.status in ('pending', 'ready') and ma.created_at < now() - p_older
     order by ma.created_at
     limit p_limit
     for update skip locked                          -- chat_send() locks the media row too
  loop
    -- Re-check AFTER the row lock, in a new statement (= new snapshot): a message committed between
    -- our scan and our lock is visible here. This closes the race with chat_send().
    if exists (select 1 from messages m where m.media_id = r.mid) then continue; end if;
    return query
      update media_assets ma set status = 'deleted'
       where ma.id = r.mid
      returning ma.id, ma.storage, ma.storage_key;
  end loop;
end $$;

commit;

-- OPERATIONS
--   * Also add a bucket lifecycle rule (e.g. abort incomplete uploads / expire chat/ objects that
--     stay unreferenced): a presigned PUT cannot cap the size, so an abusive client could upload a
--     huge object that is rejected by /complete but still sits in the bucket until it is removed.
