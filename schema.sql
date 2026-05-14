-- ============================================================
-- Nexacore Device Check — Database Schema (Phase 1)
-- ============================================================

-- Enable extensions
create extension if not exists "uuid-ossp";
create extension if not exists "pgcrypto";

-- ============================================================
-- PARTNERS — insurer/telco/MVNO clients of Nexacore
-- ============================================================
create table partners (
  id uuid primary key default uuid_generate_v4(),
  name text not null,
  slug text unique not null,                    -- url-safe identifier
  api_key text unique not null,                 -- partner-side auth
  webhook_url text,                             -- where results POST to
  webhook_secret text,                          -- HMAC signing key
  logo_url text,
  brand_color_primary text default '#44C0C5',
  brand_color_dark text default '#06444A',
  default_language text default 'en',           -- 'en' | 'ms'
  pass_fail_thresholds jsonb default '{
    "critical_checks": ["identity", "camera"],
    "allowed_non_critical_failures": 0,
    "touch_zones_required": 5
  }'::jsonb,
  consent_method text default 'partner_captured', -- partner_captured | in_app | none
  active boolean default true,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- Seed the demo partner (Nexacore itself)
insert into partners (name, slug, api_key, default_language)
values (
  'Nexacore Demo',
  'nexacore-demo',
  'nx_demo_' || encode(gen_random_bytes(16), 'hex'),
  'en'
);

-- ============================================================
-- SESSIONS — one row per device check (Stage 1 + Stage 2)
-- ============================================================
create table sessions (
  id uuid primary key default uuid_generate_v4(),
  partner_id uuid not null references partners(id) on delete restrict,
  policy_ref text,                              -- partner's reference (policy/quote id)
  consent_id text,                              -- partner's consent record id
  consent_timestamp timestamptz,
  token text unique not null default encode(gen_random_bytes(18), 'hex'),
  language text default 'en',

  -- lifecycle
  status text default 'created',                -- created | stage1_in_progress | stage1_complete | stage2_in_progress | complete | failed | expired
  stage1_result text,                           -- pass | fail
  stage2_result text,                           -- pass | fail
  overall_result text,                          -- pass | fail

  -- device snapshot (captured at stage 1)
  device_brand text,
  device_model text,
  device_fingerprint text,
  device_specs jsonb,

  -- imei
  imei_extracted text,                          -- OCR result
  imei_valid boolean,                           -- Luhn + length check
  imei_screenshot_path text,                    -- storage bucket path

  -- timestamps
  created_at timestamptz default now(),
  stage1_completed_at timestamptz,
  stage2_completed_at timestamptz,
  expires_at timestamptz default (now() + interval '72 hours'),

  -- raw report
  full_report jsonb
);

create index sessions_partner_idx on sessions(partner_id);
create index sessions_token_idx on sessions(token);
create index sessions_status_idx on sessions(status);
create index sessions_expires_idx on sessions(expires_at);

-- ============================================================
-- DIAGNOSTICS — individual check results
-- ============================================================
create table diagnostics (
  id uuid primary key default uuid_generate_v4(),
  session_id uuid references sessions(id) on delete cascade,
  check_name text not null,                     -- identity | camera | sensors | mic | speaker | screen | storage
  status text not null,                         -- passed | failed | warning
  data jsonb,
  created_at timestamptz default now()
);

create index diagnostics_session_idx on diagnostics(session_id);

-- ============================================================
-- PHOTOS — condition photos uploaded in stage 2
-- ============================================================
create table photos (
  id uuid primary key default uuid_generate_v4(),
  session_id uuid references sessions(id) on delete cascade,
  slot text not null,                           -- screen | back
  storage_path text not null,                   -- bucket path
  size_bytes integer,
  mime_type text,
  uploaded_at timestamptz default now()
);

create index photos_session_idx on photos(session_id);

-- ============================================================
-- WEBHOOK DELIVERY LOG
-- ============================================================
create table webhook_deliveries (
  id uuid primary key default uuid_generate_v4(),
  session_id uuid references sessions(id) on delete cascade,
  partner_id uuid references partners(id) on delete cascade,
  url text not null,
  payload jsonb,
  status_code integer,
  response_body text,
  attempt_count integer default 1,
  delivered boolean default false,
  last_attempted_at timestamptz default now(),
  created_at timestamptz default now()
);

create index webhook_deliveries_session_idx on webhook_deliveries(session_id);

-- ============================================================
-- AUDIT LOG — append-only event trail for compliance
-- ============================================================
create table audit_log (
  id uuid primary key default uuid_generate_v4(),
  session_id uuid references sessions(id) on delete set null,
  partner_id uuid references partners(id) on delete set null,
  event_type text not null,
  event_data jsonb,
  ip_address inet,
  user_agent text,
  created_at timestamptz default now()
);

create index audit_log_session_idx on audit_log(session_id);
create index audit_log_created_idx on audit_log(created_at desc);

-- ============================================================
-- Row Level Security
-- ============================================================
alter table partners enable row level security;
alter table sessions enable row level security;
alter table diagnostics enable row level security;
alter table photos enable row level security;
alter table webhook_deliveries enable row level security;
alter table audit_log enable row level security;

-- Service role bypasses RLS automatically (used by backend functions)
-- Anon role gets no access by default — we'll add scoped policies later
-- when the frontend talks directly to the DB via session token.

-- ============================================================
-- updated_at trigger for partners
-- ============================================================
create or replace function set_updated_at() returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

create trigger partners_updated_at
  before update on partners
  for each row execute function set_updated_at();
