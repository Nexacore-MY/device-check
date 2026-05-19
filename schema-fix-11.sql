-- ============================================================
-- Migration 11 — Lock down session-completion RPCs
-- ============================================================
-- Code review found that session_complete_stage1/2 had no status or
-- expiry guards. A DevTools user could overwrite a 'failed' session
-- back to 'complete' / 'pass'. This adds the missing checks.
-- ============================================================

insert into schema_migrations (version) values ('11-rpc-status-guards')
  on conflict do nothing;

-- ------------------------------------------------------------
-- session_complete_stage1 — refuse to update if session is terminal or expired
-- ------------------------------------------------------------
create or replace function session_complete_stage1(
  p_token text,
  p_result text,
  p_imei_extracted text,
  p_full_report jsonb
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session_id uuid;
  v_partner_id uuid;
  v_status text;
  v_expires timestamptz;
begin
  select id, partner_id, status, expires_at
    into v_session_id, v_partner_id, v_status, v_expires
    from sessions where token = p_token;

  if v_session_id is null then
    raise exception 'session not found' using errcode = '42501';
  end if;
  if v_expires < now() then
    raise exception 'session expired' using errcode = '42501';
  end if;
  if v_status in ('failed', 'expired', 'complete') then
    raise exception 'session is terminal (status=%)', v_status using errcode = '42501';
  end if;
  if p_result not in ('pass', 'fail') then
    raise exception 'invalid result' using errcode = '22023';
  end if;

  update sessions set
    status = 'stage1_complete',
    stage1_result = p_result,
    stage1_completed_at = now(),
    imei_extracted = coalesce(imei_extracted, p_imei_extracted),
    full_report = p_full_report
  where id = v_session_id;

  insert into audit_log (session_id, partner_id, event_type, actor_type, event_data)
  values (v_session_id, v_partner_id, 'stage1_completed', 'customer',
          jsonb_build_object('result', p_result));
end;
$$;

grant execute on function session_complete_stage1(text, text, text, jsonb) to anon;

-- ------------------------------------------------------------
-- session_complete_stage2 — same guards; cannot overwrite a 'failed' or 'complete' session
-- ------------------------------------------------------------
create or replace function session_complete_stage2(
  p_token text,
  p_result text,
  p_full_report jsonb
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session_id uuid;
  v_partner_id uuid;
  v_status text;
  v_expires timestamptz;
begin
  select id, partner_id, status, expires_at
    into v_session_id, v_partner_id, v_status, v_expires
    from sessions where token = p_token;

  if v_session_id is null then
    raise exception 'session not found' using errcode = '42501';
  end if;
  if v_expires < now() then
    raise exception 'session expired' using errcode = '42501';
  end if;
  if v_status in ('failed', 'expired', 'complete') then
    raise exception 'session is terminal (status=%)', v_status using errcode = '42501';
  end if;
  if p_result not in ('pass', 'fail') then
    raise exception 'invalid result' using errcode = '22023';
  end if;

  update sessions set
    status = 'complete',
    stage2_result = p_result,
    stage2_completed_at = now(),
    overall_result = p_result,
    full_report = p_full_report
  where id = v_session_id;

  insert into audit_log (session_id, partner_id, event_type, actor_type, event_data)
  values (v_session_id, v_partner_id, 'stage2_completed', 'customer',
          jsonb_build_object('result', p_result));
end;
$$;

grant execute on function session_complete_stage2(text, text, jsonb) to anon;
