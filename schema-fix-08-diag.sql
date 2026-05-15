-- ============================================================
-- Migration 08 (diagnostic) — temporary wide-open policy
-- ============================================================
-- Just to test whether ANY policy works for anon uploads.
-- If uploads succeed with this, we know the issue is specific.
-- We'll lock back down once we figure out what's happening.

drop policy if exists "diag_open_upload" on storage.objects;

create policy "diag_open_upload" on storage.objects
  for insert
  with check (true);
