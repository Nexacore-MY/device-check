-- schema-fix-15.sql — make a Stage-2 'pass' server-authoritative.
--
-- Adds to the existing (schema-fix-12) photo guard: a 'pass' also requires the session to
-- have PASSED stage 1 and to hold an extracted IMEI. Prevents a second phone (which lacks
-- stage-1 data) — or any client — from claiming a 'pass' the stored evidence doesn't support.
-- Additive redefinition; same signature + grant as schema-fix-04/11/12, so deploy-safe.
create or replace function session_complete_stage2(
  p_token text, p_result text, p_full_report jsonb
) returns void language plpgsql security definer set search_path = public as $$
declare
  v_session_id uuid;
  v_status text;
  v_expires timestamptz;
  v_stage1 text;
  v_imei text;
  v_accepted_slots int;
begin
  select id, status, expires_at, stage1_result, imei_extracted
    into v_session_id, v_status, v_expires, v_stage1, v_imei
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

  -- A 'pass' must be backed by stored evidence: both photos accepted, stage 1 passed, IMEI on record.
  if p_result = 'pass' then
    select count(*) into v_accepted_slots
      from photos
      where session_id = v_session_id
        and slot in ('screen', 'back')
        and (status is null or status = 'accepted');
    if v_accepted_slots < 2 then
      raise exception 'cannot mark pass: only % of 2 required photos accepted', v_accepted_slots using errcode = '42501';
    end if;
    if v_stage1 is distinct from 'pass' then
      raise exception 'cannot mark pass: stage 1 did not pass (%)', coalesce(v_stage1, 'null') using errcode = '42501';
    end if;
    if v_imei is null or length(v_imei) = 0 then
      raise exception 'cannot mark pass: no IMEI on record' using errcode = '42501';
    end if;
  end if;

  update sessions set
    status = 'complete',
    stage2_result = p_result,
    stage2_completed_at = now(),
    overall_result = p_result,
    full_report = p_full_report
  where id = v_session_id;
end;
$$;

-- Only the customer app (anon) calls this, matching the prior versions.
revoke all on function session_complete_stage2(text, text, jsonb) from public;
grant execute on function session_complete_stage2(text, text, jsonb) to anon;
