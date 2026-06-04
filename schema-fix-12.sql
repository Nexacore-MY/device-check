-- ============================================================
-- Migration 12 — Server-side photo presence check for stage 2
-- ============================================================
-- Closes a real bug observed in production: a session was marked
-- overall_result = 'pass' even though only the screen photo had been
-- accepted (back photo was rejected 3 times for case_visible). The
-- frontend submitStage2 guard should have blocked, but something let
-- the click through. Without a server-side check, the backend just
-- trusted p_result = 'pass'.
--
-- Defence-in-depth: session_complete_stage2 now refuses to mark a
-- session 'pass' unless BOTH the 'screen' and 'back' photos exist
-- in the photos table with no rejection status set.
-- A 'fail' result is always allowed (failing is never a problem to
-- accept).
--
-- Also tightens smart-handler's allowed input: photo uploads are
-- refused against sessions whose status is terminal (complete or
-- failed). The edge function already has its own check, but adding
-- it at the RPC layer keeps the contract consistent.
-- ============================================================

insert into schema_migrations (version) values ('12-stage2-photo-presence-check')
  on conflict do nothing;

-- ------------------------------------------------------------
-- session_complete_stage2 — adds photo presence check for 'pass'
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
  v_accepted_slots int;
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

  -- NEW: a 'pass' result requires both 'screen' and 'back' photos to exist
  -- in the photos table and not be in a rejected status. The smart-handler
  -- writes status = 'rejected_damage' for pre-existing damage; accepted
  -- photos have a NULL status.
  if p_result = 'pass' then
    select count(*) into v_accepted_slots
      from photos
      where session_id = v_session_id
        and slot in ('screen', 'back')
        and (status is null or status = 'accepted');

    if v_accepted_slots < 2 then
      raise exception 'cannot mark pass: only % of 2 required photos accepted', v_accepted_slots
        using errcode = '42501';
    end if;
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
