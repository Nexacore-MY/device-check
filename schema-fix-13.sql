-- schema-fix-13.sql — session_refund_upload_quota: give back a consumed upload slot.
--
-- session_check_upload_quota (schema-fix-09) increments upload_count_imei/photo on
-- EVERY call, including ones that then fail for infra reasons (Vision/Gemini timeout
-- or outage). Combined with the analysis timeout, a customer on a slow backend burns
-- their quota on failed calls and the link locks before they finish their two photos.
-- The edge function now refunds the slot whenever an upload fails for an infra reason,
-- so only real attempts count. Port of Device-check-prod 20260616000000_refund_upload_quota.sql.
--
-- Called only from the edge function (service_role), matching session_check_upload_quota.
-- greatest(... - 1, 0) keeps the counter from going negative.

create or replace function session_refund_upload_quota(
  p_token text,
  p_kind text
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_kind = 'imei' then
    update sessions
      set upload_count_imei = greatest(upload_count_imei - 1, 0)
      where token = p_token;
  else
    update sessions
      set upload_count_photo = greatest(upload_count_photo - 1, 0)
      where token = p_token;
  end if;
end;
$$;

-- Lock it down: only the edge function (service_role) ever calls this. The default
-- PUBLIC execute grant would let a customer invoke it directly via PostgREST (anon
-- key) to reset their own upload counter and defeat the per-session cap + lockout.
revoke all on function session_refund_upload_quota(text, text) from public, anon, authenticated;
grant execute on function session_refund_upload_quota(text, text) to service_role;
