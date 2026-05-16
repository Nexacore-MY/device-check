-- ============================================================
-- Migration 10 — Damage-rejected photos preserved as evidence
-- ============================================================
-- When LLM detects pre-existing damage, we now KEEP the photo
-- (for partner review + audit) and mark the session as failed.
-- New status column distinguishes accepted vs damage-rejected photos.
-- ============================================================

insert into schema_migrations (version) values ('10-photo-status')
  on conflict do nothing;

-- Add status column to photos
alter table photos
  add column if not exists status text not null default 'accepted';

-- CHECK constraint (drop+recreate idempotent)
alter table photos drop constraint if exists photos_status_check;
alter table photos
  add constraint photos_status_check
  check (status in ('accepted', 'rejected_damage'));

-- Index for partner queries filtering by status
create index if not exists photos_status_idx on photos(status);
