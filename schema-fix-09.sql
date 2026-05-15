-- ============================================================
-- Migration 09 — Phase 4 hardening
--   1. admin_list_sessions returns IMEI for dashboard display
--   2. Rate-limit table + upload counter
--   3. Lock down storage RLS (only service_role can write)
--   4. Cleanup unused storage helper RPCs
-- ============================================================

insert into schema_migrations (version) values ('09-phase4-hardening')
  on conflict do nothing;

-- ------------------------------------------------------------
-- 1. admin_list_sessions — add IMEI fields to return
-- ------------------------------------------------------------
drop function if exists admin_list_sessions(text, text, int);

create or replace function admin_list_sessions(
  p_admin_token text,
  p_partner_slug text,
  p_limit int default 20
) returns table(
  id uuid,
  token text,
  policy_ref text,
  status text,
  stage1_result text,
  stage2_result text,
  overall_result text,
  device_brand text,
  device_model text,
  language text,
  imei_extracted text,
  imei_valid boolean,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_partner_id uuid;
begin
  if p_admin_token is null or length(p_admin_token) < 10 then
    raise exception 'unauthorized' using errcode = '42501';
  end if;

  select p.id into v_partner_id
    from partners p
    where p.slug = p_partner_slug
      and p.active = true
      and p.admin_token = p_admin_token;

  if v_partner_id is null then
    raise exception 'unauthorized' using errcode = '42501';
  end if;

  return query
    select s.id, s.token, s.policy_ref, s.status, s.stage1_result,
           s.stage2_result, s.overall_result, s.device_brand, s.device_model,
           s.language, s.imei_extracted, s.imei_valid, s.created_at
      from sessions s
      where s.partner_id = v_partner_id
      order by s.created_at desc
      limit least(p_limit, 100);
end;
$$;

grant execute on function admin_list_sessions(text, text, int) to anon;

-- ------------------------------------------------------------
-- 2. Rate-limit infrastructure
-- ------------------------------------------------------------

-- Per-session upload counter on sessions table
alter table sessions
  add column if not exists upload_count_imei int not null default 0,
  add column if not exists upload_count_photo int not null default 0;

-- Per-IP rate limit table (1-minute bucket)
create table if not exists rate_limits (
  ip inet not null,
  minute_bucket timestamptz not null,
  count int not null default 1,
  primary key (ip, minute_bucket)
);

alter table rate_limits enable row level security;
-- No policies = service-role only access

-- Helper: check + increment in a transaction
create or replace function rl_check_and_increment(
  p_ip inet,
  p_per_minute_limit int default 30
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bucket timestamptz;
  v_count int;
begin
  v_bucket := date_trunc('minute', now());

  insert into rate_limits (ip, minute_bucket, count)
  values (p_ip, v_bucket, 1)
  on conflict (ip, minute_bucket) do update
    set count = rate_limits.count + 1
  returning count into v_count;

  -- Purge old buckets opportunistically (cheap)
  delete from rate_limits where minute_bucket < now() - interval '10 minutes';

  return v_count <= p_per_minute_limit;
end;
$$;

-- Per-session upload increment + cap check
create or replace function session_check_upload_quota(
  p_token text,
  p_kind text,
  p_imei_max int default 5,
  p_photo_max int default 10
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int;
begin
  if p_kind = 'imei' then
    update sessions set upload_count_imei = upload_count_imei + 1
      where token = p_token
      returning upload_count_imei into v_count;
    return v_count is not null and v_count <= p_imei_max;
  else
    update sessions set upload_count_photo = upload_count_photo + 1
      where token = p_token
      returning upload_count_photo into v_count;
    return v_count is not null and v_count <= p_photo_max;
  end if;
end;
$$;

-- ------------------------------------------------------------
-- 3. Lock down storage RLS — only service_role can write
-- ------------------------------------------------------------
-- All client uploads now go through the edge function (which uses service_role).
-- Direct client uploads should fail.

drop policy if exists "diag_open_upload" on storage.objects;
drop policy if exists "upload_imei" on storage.objects;
drop policy if exists "upload_photos" on storage.objects;
drop policy if exists "update_imei" on storage.objects;
drop policy if exists "update_photos" on storage.objects;
-- Anon was never granted by us; service_role bypasses RLS regardless

-- ------------------------------------------------------------
-- 4. Cleanup unused storage helper RPCs (replaced by edge function)
-- ------------------------------------------------------------
drop function if exists session_get_storage_paths(text);
drop function if exists session_record_imei(text, text, integer, text);
drop function if exists session_record_photo(text, text, text, integer, text);
