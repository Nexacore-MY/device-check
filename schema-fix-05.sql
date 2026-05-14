-- ============================================================
-- Migration 05 — session_get includes full_report for resume
-- ============================================================
insert into schema_migrations (version) values ('05-session-get-full-report')
  on conflict do nothing;

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
      'expires_at', v_session.expires_at,
      'full_report', v_session.full_report
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
