-- ============================================================
-- Migration 01 — fix token default + tighten session constraints
-- ============================================================

-- 1. Replace token default with URL-safe hex (36 chars, 144 bits entropy)
alter table sessions
  alter column token set default encode(gen_random_bytes(18), 'hex');

-- 2. partner_id must always be set
alter table sessions
  alter column partner_id set not null;

-- 3. Useful composite index for listing partner sessions by recency
create index if not exists sessions_partner_created_idx
  on sessions(partner_id, created_at desc);
