-- schema-fix-14.sql — rate limiter keyed by a generic text key (was inet).
--
-- Fixes the demo killer: unknown-IP traffic (proxy/tunnel strips x-forwarded-for) was
-- all bucketed under one global "0.0.0.0" inet at 10/min shared — so behind a tunnel the
-- WHOLE demo shared one counter, and the QR hand-off (two phones per session) doubled it.
-- The edge fn now passes the IP when known, else 'sess:<token>', so each session gets its
-- own bucket. Caps raised to demo-tuned values in the edge fn (revisit for production).

-- rate_limits.ip (inet, part of the PK) -> rl_key (text). The PK (ip, minute_bucket)
-- survives the rename; we only widen the type so 'sess:<token>' keys fit.
alter table rate_limits rename column ip to rl_key;
alter table rate_limits alter column rl_key type text;

-- Replace the inet-typed function with a text-keyed one.
drop function if exists rl_check_and_increment(inet, int);
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

  insert into rate_limits (rl_key, minute_bucket, count)
  values (p_key, v_bucket, 1)
  on conflict (rl_key, minute_bucket) do update
    set count = rate_limits.count + 1
  returning count into v_count;

  delete from rate_limits where minute_bucket < now() - interval '10 minutes';

  return v_count <= p_per_minute_limit;
end;
$$;
