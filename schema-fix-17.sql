-- schema-fix-17.sql — BD demo passes: one permanent QR code that starts a fresh demo per tap.
--
-- WHY: every demo needed a link minted in the admin (admin_create_session needs the admin
-- token) and each link works for one device, one run. Melanie (2026-10-19): the new Business
-- Development person wants to demonstrate Device Check "without having to create a new QR
-- code every time". Design: context-nexa product/bd-demo-links.md (Option 2).
--
-- HOW: a QR code points at https://demo.nexcheck.io/start/#c=<code>. Tapping "Start demo" on
-- that page calls demo_start_session(<code>), which mints an ordinary session and returns only
-- its token; the page then opens the normal app with it. Every tap is a brand-new session with
-- its own upload cap, so demos never share or exhaust each other's slots.
--
-- CONTRACT:
--   * The printed code is effectively public once it is on a card — the CAPS are the control,
--     not the code. Each pass has a per-hour and per-day limit, counted from its own sessions
--     under a row lock so simultaneous taps cannot overshoot it.
--   * The code is stored only as a sha256 hex digest; the plaintext exists only in the QR.
--   * The function never touches or needs the admin token, and returns nothing but the token
--     of the session it just created. Wrong, switched-off and expired passes all get the same
--     answer (demo_link_invalid) so the page reveals nothing about which codes exist.
--   * Demo sessions live under their own partner (nexacore-bd-demo), so they never mix with the
--     prospect evaluations under nexacore-demo, and BD can be given an admin view of only them
--     (admin-config.js: DEMO_PARTNER_SLUG + that partner's admin_token).
--   * Demo sessions expire after session_hours (default 4), not the 72h column default.
--
-- Apply by hand in the Supabase SQL editor (the live DB password is not available to us).
-- Safe to re-run. Tests: scripts/demo-pass-test.sql (throwaway DB only).

insert into schema_migrations (version) values ('17-demo-passes')
  on conflict do nothing;

-- 1. The BD demo partner. Same customer-facing name as the existing demo partner, because the
--    app shows it on the final screen ("Your device assessment has been sent to …").
insert into partners (name, slug, api_key, admin_token, default_language)
values (
  'Nexacore Demo',
  'nexacore-bd-demo',
  'nx_bd_' || encode(extensions.gen_random_bytes(16), 'hex'),
  'nxa_'   || encode(extensions.gen_random_bytes(24), 'hex'),
  'en'
)
on conflict (slug) do nothing;

-- 2. Demo passes — one row per printed QR code (per BD person or per event).
create table if not exists demo_links (
  id            uuid primary key default gen_random_uuid(),
  partner_id    uuid not null references partners(id) on delete restrict,
  label         text not null unique check (label ~ '^[a-z0-9][a-z0-9-]{1,39}$'),
  code_hash     text not null unique,                  -- sha256 hex of the code in the QR
  active        boolean not null default true,         -- the off switch
  language      text not null default 'en' check (language in ('en', 'ms')),
  per_hour      int not null default 6 check (per_hour > 0),
  per_day       int not null default 20 check (per_day >= per_hour),
  session_hours int not null default 4 check (session_hours between 1 and 72),
  valid_until   timestamptz,                           -- null = no end date
  created_at    timestamptz not null default now()
);

alter table demo_links enable row level security;   -- no policies: deny-all, like every table
revoke all on demo_links from anon, authenticated;

-- 3. Which pass created a session (null for every normally minted session).
alter table sessions
  add column if not exists demo_link_id uuid references demo_links(id) on delete set null;
create index if not exists sessions_demo_link_idx
  on sessions (demo_link_id, created_at desc) where demo_link_id is not null;

-- 4. The one function the start page calls.
create or replace function demo_start_session(p_code text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_link     demo_links%rowtype;
  v_hour     int;
  v_day      int;
  v_session  uuid;
  v_token    text;
begin
  if p_code is null or length(p_code) < 16 or length(p_code) > 128 then
    raise exception 'demo_link_invalid';
  end if;

  -- Lock the pass row: concurrent taps on one pass queue here, so the counts below are exact.
  select * into v_link
    from demo_links
   where code_hash = encode(sha256(convert_to(p_code, 'UTF8')), 'hex')
   for update;

  if not found
     or not v_link.active
     or (v_link.valid_until is not null and v_link.valid_until < now())
     or not exists (select 1 from partners where id = v_link.partner_id and active) then
    raise exception 'demo_link_invalid';
  end if;

  select count(*) filter (where created_at > now() - interval '1 hour'),
         count(*) filter (where created_at > now() - interval '24 hours')
    into v_hour, v_day
    from sessions
   where demo_link_id = v_link.id;

  if v_hour >= v_link.per_hour or v_day >= v_link.per_day then
    raise exception 'demo_limit_reached';
  end if;

  insert into sessions (partner_id, policy_ref, language, status, expires_at, demo_link_id)
  values (
    v_link.partner_id,
    'demo-' || v_link.label || '-' || to_char(now() at time zone 'Asia/Kuala_Lumpur', 'YYMMDD-HH24MISS'),
    v_link.language,
    'created',
    now() + make_interval(hours => v_link.session_hours),
    v_link.id
  )
  returning id, token into v_session, v_token;

  insert into audit_log (session_id, partner_id, event_type, actor_type, event_data)
  values (v_session, v_link.partner_id, 'session_created_via_demo_link', 'customer',
          jsonb_build_object('demo_link', v_link.label));

  return v_token;
end;
$$;

revoke all on function demo_start_session(text) from public, anon, authenticated;
grant execute on function demo_start_session(text) to anon;
