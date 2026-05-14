-- ============================================================
-- Migration 02 — schema hardening from independent review
-- Apply after schema-fix-01.sql
-- ============================================================

-- ------------------------------------------------------------
-- 1. Migration tracking table (so we know what's been applied)
-- ------------------------------------------------------------
create table if not exists schema_migrations (
  version text primary key,
  applied_at timestamptz default now()
);

alter table schema_migrations enable row level security;

insert into schema_migrations (version) values ('01-token-fix-and-not-null')
  on conflict do nothing;
insert into schema_migrations (version) values ('02-hardening')
  on conflict do nothing;

-- ------------------------------------------------------------
-- 2. Defence-in-depth: explicitly revoke public-schema access
--    from anon/authenticated roles. Service role bypasses RLS.
-- ------------------------------------------------------------
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from anon, authenticated;

-- ------------------------------------------------------------
-- 3. CHECK constraints on enum-like text columns
-- ------------------------------------------------------------
alter table partners
  add constraint partners_language_check
    check (default_language in ('en', 'ms')),
  add constraint partners_consent_method_check
    check (consent_method in ('partner_captured', 'in_app', 'none'));

alter table sessions
  add constraint sessions_status_check
    check (status in ('created', 'stage1_in_progress', 'stage1_complete',
                      'stage2_in_progress', 'complete', 'failed', 'expired')),
  add constraint sessions_stage1_result_check
    check (stage1_result is null or stage1_result in ('pass', 'fail')),
  add constraint sessions_stage2_result_check
    check (stage2_result is null or stage2_result in ('pass', 'fail')),
  add constraint sessions_overall_result_check
    check (overall_result is null or overall_result in ('pass', 'fail')),
  add constraint sessions_language_check
    check (language in ('en', 'ms'));

alter table diagnostics
  add constraint diagnostics_check_name_check
    check (check_name in ('identity', 'camera', 'sensors', 'mic',
                          'speaker', 'screen', 'storage')),
  add constraint diagnostics_status_check
    check (status in ('passed', 'failed', 'warning'));

alter table photos
  add constraint photos_slot_check
    check (slot in ('screen', 'back')),
  add constraint photos_size_check
    check (size_bytes is null or size_bytes < 15728640);  -- 15 MB

-- ------------------------------------------------------------
-- 4. NOT NULL where orphans don't make sense
-- ------------------------------------------------------------
alter table diagnostics alter column session_id set not null;
alter table photos      alter column session_id set not null;

-- ------------------------------------------------------------
-- 5. Prevent duplicate photos per slot per session
-- ------------------------------------------------------------
alter table photos
  add constraint photos_session_slot_unique unique (session_id, slot);

-- ------------------------------------------------------------
-- 6. updated_at on sessions (debugging stuck sessions)
-- ------------------------------------------------------------
alter table sessions add column if not exists updated_at timestamptz default now();

drop trigger if exists sessions_updated_at on sessions;
create trigger sessions_updated_at
  before update on sessions
  for each row execute function set_updated_at();

-- ------------------------------------------------------------
-- 7. Partial index for expiry sweep (skips finished sessions)
-- ------------------------------------------------------------
drop index if exists sessions_expires_idx;
create index sessions_active_expires_idx
  on sessions(expires_at)
  where status not in ('complete', 'failed', 'expired');

-- ------------------------------------------------------------
-- 8. Audit log: actor identity + immutability
-- ------------------------------------------------------------
alter table audit_log
  add column if not exists actor_type text,
  add column if not exists actor_id text,
  add constraint audit_log_actor_type_check
    check (actor_type is null or actor_type in ('partner', 'customer', 'system', 'admin'));

-- Block UPDATE and DELETE on audit_log to enforce append-only
create or replace function audit_log_immutable() returns trigger as $$
begin
  raise exception 'audit_log is append-only';
end;
$$ language plpgsql;

drop trigger if exists audit_log_no_update on audit_log;
create trigger audit_log_no_update
  before update or delete on audit_log
  for each row execute function audit_log_immutable();
