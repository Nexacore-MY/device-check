-- schema-fix-14.sql — add a text-keyed rate limiter ALONGSIDE the existing inet one.
--
-- DEPLOY-SAFE / backward-compatible. The currently-deployed edge function calls
-- rl_check_and_increment(p_ip inet, ...). We do NOT touch that function or its table,
-- so the live demo keeps working the moment this runs. We ADD an overload
-- rl_check_and_increment(p_key text, ...) + its own table; the NEW edge function calls
-- the text overload (IP when known, else 'sess:<token>'), removing the demo killer where
-- all unknown-IP traffic (tunnel/proxy) shared one global "0.0.0.0" 10/min bucket.
-- Run this first; deploy the new edge fn after — no breakage window either way.
-- (Optional future cleanup once the old edge fn is retired: drop the inet overload + rate_limits.)

create table if not exists rate_limits_text (
  rl_key text not null,
  minute_bucket timestamptz not null,
  count int not null default 1,
  primary key (rl_key, minute_bucket)
);
alter table rate_limits_text enable row level security;  -- no policies = service-role only

create or replace function rl_check_and_increment(
  p_key text,
  p_per_minute_limit int default 60
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

  insert into rate_limits_text (rl_key, minute_bucket, count)
  values (p_key, v_bucket, 1)
  on conflict (rl_key, minute_bucket) do update
    set count = rate_limits_text.count + 1
  returning count into v_count;

  delete from rate_limits_text where minute_bucket < now() - interval '10 minutes';

  return v_count <= p_per_minute_limit;
end;
$$;
