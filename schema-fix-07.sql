-- ============================================================
-- Migration 07 — Fix storage upload RLS policies
-- ============================================================
-- The 'to anon' role specifier didn't match Supabase storage's
-- internal auth context. Switching to implicit (public) role
-- which works for both anon and authenticated.

insert into schema_migrations (version) values ('07-storage-rls-fix')
  on conflict do nothing;

-- Drop the old policies
drop policy if exists "anon_upload_imei" on storage.objects;
drop policy if exists "anon_upload_photos" on storage.objects;

-- Recreate without 'to anon' — applies to all roles
create policy "upload_imei" on storage.objects
  for insert
  with check (bucket_id = 'imei_screenshots');

create policy "upload_photos" on storage.objects
  for insert
  with check (bucket_id = 'condition_photos');

-- Also allow updates (needed for upsert: true) on the same buckets
create policy "update_imei" on storage.objects
  for update
  using (bucket_id = 'imei_screenshots')
  with check (bucket_id = 'imei_screenshots');

create policy "update_photos" on storage.objects
  for update
  using (bucket_id = 'condition_photos')
  with check (bucket_id = 'condition_photos');
