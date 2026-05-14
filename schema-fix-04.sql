-- ============================================================
-- Migration 04 — Customer-facing RPC functions
-- ============================================================
-- The device check frontend (index.html) calls these via the
-- publishable key. Each is gated by the session token from the URL.

insert into schema_migrations (version) values ('04-session-rpc')
  on conflict do nothing;

-- ------------------------------------------------------------
-- 1. session_get — bootstrap data on page load
-- ------------------------------------------------------------
create or replace function session_get(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session sessions;
  v_partner partners;
begin
  if p_token is null or length(p_token) < 10 then
    raise exception 'invalid token' using errcode = '42501';
  end if;

  select * into v_session from sessions where token = p_token;
  if v_session.id is null then
    raise exception 'session not found' using errcode = '42501';
  end if;

  if v_session.expires_at < now() and v_session.status not in ('complete') then
    update sessions set status = 'expired' where id = v_session.id;
    raise exception 'session expired' using errcode = '42501';
  end if;

  select * into v_partner from partners where id = v_session.partner_id;

  return jsonb_build_object(
    'session', jsonb_build_object(
      'token', v_session.token,
      'status', v_session.status,
      'language', v_session.language,
      'policy_ref', v_session.policy_ref,
      'stage1_completed_at', v_session.stage1_completed_at,
      'stage2_completed_at', v_session.stage2_completed_at,
      'device_brand', v_session.device_brand,
      'device_model', v_session.device_model,
      'device_fingerprint', v_session.device_fingerprint,
      'stage1_result', v_session.stage1_result,
      'stage2_result', v_session.stage2_result,
      'overall_result', v_session.overall_result,
      'expires_at', v_session.expires_at
    ),
    'partner', jsonb_build_object(
      'name', v_partner.name,
      'logo_url', v_partner.logo_url,
      'brand_color_primary', v_partner.brand_color_primary,
      'brand_color_dark', v_partner.brand_color_dark
    ),
    'thresholds', v_partner.pass_fail_thresholds
  );
end;
$$;

grant execute on function session_get(text) to anon;

-- ------------------------------------------------------------
-- 2. session_record_scan — save device info + all diagnostics
-- ------------------------------------------------------------
create or replace function session_record_scan(
  p_token text,
  p_device_brand text,
  p_device_model text,
  p_fingerprint text,
  p_specs jsonb,
  p_diagnostics jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session_id uuid;
  v_diag jsonb;
begin
  select id into v_session_id from sessions
    where token = p_token and expires_at > now();
  if v_session_id is null then
    raise exception 'session not found or expired' using errcode = '42501';
  end if;

  update sessions set
    status = case when status = 'created' then 'stage1_in_progress' else status end,
    device_brand = p_device_brand,
    device_model = p_device_model,
    device_fingerprint = p_fingerprint,
    device_specs = p_specs
  where id = v_session_id;

  delete from diagnostics where session_id = v_session_id;

  for v_diag in select * from jsonb_array_elements(p_diagnostics) loop
    insert into diagnostics (session_id, check_name, status, data)
    values (v_session_id, v_diag->>'check_name', v_diag->>'status', v_diag->'data');
  end loop;
end;
$$;

grant execute on function session_record_scan(text, text, text, text, jsonb, jsonb) to anon;

-- ------------------------------------------------------------
-- 3. session_complete_stage1
-- ------------------------------------------------------------
create or replace function session_complete_stage1(
  p_token text,
  p_result text,
  p_imei_extracted text,
  p_full_report jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session_id uuid;
  v_partner_id uuid;
begin
  select id, partner_id into v_session_id, v_partner_id
    from sessions where token = p_token and expires_at > now();
  if v_session_id is null then
    raise exception 'session not found or expired' using errcode = '42501';
  end if;
  if p_result not in ('pass', 'fail') then
    raise exception 'invalid result' using errcode = '22023';
  end if;

  update sessions set
    status = 'stage1_complete',
    stage1_result = p_result,
    stage1_completed_at = now(),
    imei_extracted = p_imei_extracted,
    full_report = p_full_report
  where id = v_session_id;

  insert into audit_log (session_id, partner_id, event_type, actor_type, event_data)
  values (v_session_id, v_partner_id, 'stage1_completed', 'customer',
          jsonb_build_object('result', p_result));
end;
$$;

grant execute on function session_complete_stage1(text, text, text, jsonb) to anon;

-- ------------------------------------------------------------
-- 4. session_complete_stage2
-- ------------------------------------------------------------
create or replace function session_complete_stage2(
  p_token text,
  p_result text,
  p_full_report jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session_id uuid;
  v_partner_id uuid;
begin
  select id, partner_id into v_session_id, v_partner_id
    from sessions where token = p_token;
  if v_session_id is null then
    raise exception 'session not found' using errcode = '42501';
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
