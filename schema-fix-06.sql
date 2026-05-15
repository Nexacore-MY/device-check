-- ============================================================
-- Migration 06 — Storage RPC functions + bucket policies
-- ============================================================
-- Pattern: app calls RPC to get the storage path to write to (validates session),
-- uploads directly to Supabase Storage using the publishable key,
-- then calls a record RPC to log the upload metadata.

insert into schema_migrations (version) values ('06-storage-rpc')
  on conflict do nothing;

-- ------------------------------------------------------------
-- 1. session_get_storage_paths — returns the paths for IMEI + photos
--    Acts as the gate: must have a valid session token to learn the paths.
-- ------------------------------------------------------------
create or replace function session_get_storage_paths(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session_id uuid;
begin
  select id into v_session_id from sessions
    where token = p_token and expires_at > now();
  if v_session_id is null then
    raise exception 'session not found or expired' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'session_id', v_session_id::text,
    'imei_prefix', v_session_id::text || '/imei',
    'photo_screen_prefix', v_session_id::text || '/screen',
    'photo_back_prefix', v_session_id::text || '/back'
  );
end;
$$;

grant execute on function session_get_storage_paths(text) to anon;

-- ------------------------------------------------------------
-- 2. session_record_imei — record IMEI upload metadata
-- ------------------------------------------------------------
create or replace function session_record_imei(
  p_token text,
  p_storage_path text,
  p_size_bytes integer,
  p_mime_type text
) returns void
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

  -- Ensure the path is scoped to this session
  if p_storage_path not like v_session_id::text || '/%' then
    raise exception 'invalid storage path' using errcode = '42501';
  end if;

  update sessions set imei_screenshot_path = p_storage_path
    where id = v_session_id;

  insert into audit_log (session_id, partner_id, event_type, actor_type, event_data)
  values (v_session_id, v_partner_id, 'imei_uploaded', 'customer',
          jsonb_build_object('size', p_size_bytes, 'mime', p_mime_type, 'path', p_storage_path));
end;
$$;

grant execute on function session_record_imei(text, text, integer, text) to anon;

-- ------------------------------------------------------------
-- 3. session_record_photo — log condition photo upload
-- ------------------------------------------------------------
create or replace function session_record_photo(
  p_token text,
  p_slot text,
  p_storage_path text,
  p_size_bytes integer,
  p_mime_type text
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session_id uuid;
  v_partner_id uuid;
begin
  if p_slot not in ('screen', 'back') then
    raise exception 'invalid slot' using errcode = '22023';
  end if;

  select id, partner_id into v_session_id, v_partner_id
    from sessions where token = p_token and expires_at > now();
  if v_session_id is null then
    raise exception 'session not found or expired' using errcode = '42501';
  end if;

  if p_storage_path not like v_session_id::text || '/%' then
    raise exception 'invalid storage path' using errcode = '42501';
  end if;

  insert into photos (session_id, slot, storage_path, size_bytes, mime_type)
  values (v_session_id, p_slot, p_storage_path, p_size_bytes, p_mime_type)
  on conflict (session_id, slot) do update set
    storage_path = excluded.storage_path,
    size_bytes = excluded.size_bytes,
    mime_type = excluded.mime_type,
    uploaded_at = now();

  insert into audit_log (session_id, partner_id, event_type, actor_type, event_data)
  values (v_session_id, v_partner_id, 'photo_uploaded', 'customer',
          jsonb_build_object('slot', p_slot, 'size', p_size_bytes, 'mime', p_mime_type, 'path', p_storage_path));
end;
$$;

grant execute on function session_record_photo(text, text, text, integer, text) to anon;

-- ============================================================
-- Storage bucket policies
-- ============================================================
-- Allow anon to INSERT into the three buckets, but no read/update/delete.
-- The path-prefix check inside the record RPCs is the real validation —
-- here we just allow the upload to happen at all.
-- Reads will go through signed URLs from a future server-side function.

-- Drop any existing policies (idempotent re-run)
drop policy if exists "anon_upload_imei" on storage.objects;
drop policy if exists "anon_upload_photos" on storage.objects;
drop policy if exists "anon_upload_reports" on storage.objects;

create policy "anon_upload_imei" on storage.objects
  for insert
  to anon
  with check (bucket_id = 'imei_screenshots');

create policy "anon_upload_photos" on storage.objects
  for insert
  to anon
  with check (bucket_id = 'condition_photos');

-- Reports bucket: anon cannot upload here. Service role only (for server-generated PDFs later).
-- No policy = denied by default.
