-- ============================================================
-- Migration 03 — Admin RPC functions
-- ============================================================
-- Privileged admin operations are exposed as security-definer RPC
-- functions gated by an admin token. This lets the local admin page
-- use the safe publishable key in the browser.

insert into schema_migrations (version) values ('03-admin-rpc')
  on conflict do nothing;

-- ------------------------------------------------------------
-- 1. Store the admin token alongside the partner that owns it.
-- ------------------------------------------------------------
alter table partners
  add column if not exists admin_token text;

-- Seed a random admin token for the demo partner if not set
update partners
  set admin_token = 'nxa_' || encode(gen_random_bytes(24), 'hex')
  where slug = 'nexacore-demo' and admin_token is null;

-- ------------------------------------------------------------
-- 2. admin_create_session — generate a session for a partner
-- ------------------------------------------------------------
create or replace function admin_create_session(
  p_admin_token text,
  p_partner_slug text,
  p_policy_ref text default null,
  p_language text default 'en'
) returns table(token text, session_id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_partner_id uuid;
  v_session_id uuid;
  v_token text;
begin
  if p_admin_token is null or length(p_admin_token) < 10 then
    raise exception 'unauthorized' using errcode = '42501';
  end if;

  -- Find partner and validate admin token in one shot
  select id into v_partner_id
    from partners
    where slug = p_partner_slug
      and active = true
      and admin_token = p_admin_token;

  if v_partner_id is null then
    raise exception 'unauthorized' using errcode = '42501';
  end if;

  if p_language not in ('en', 'ms') then
    raise exception 'invalid language: %', p_language using errcode = '22023';
  end if;

  insert into sessions (partner_id, policy_ref, language, status)
  values (v_partner_id, p_policy_ref, p_language, 'created')
  returning id, sessions.token into v_session_id, v_token;

  insert into audit_log (session_id, partner_id, event_type, actor_type, event_data)
  values (v_session_id, v_partner_id, 'session_created_via_admin', 'admin',
          jsonb_build_object('policy_ref', p_policy_ref, 'language', p_language));

  return query select v_token, v_session_id;
end;
$$;

-- ------------------------------------------------------------
-- 3. admin_list_sessions — list recent sessions for a partner
-- ------------------------------------------------------------
create or replace function admin_list_sessions(
  p_admin_token text,
  p_partner_slug text,
  p_limit int default 20
) returns table(
  id uuid,
  token text,
  policy_ref text,
  status text,
  stage1_result text,
  stage2_result text,
  overall_result text,
  device_brand text,
  device_model text,
  language text,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_partner_id uuid;
begin
  if p_admin_token is null or length(p_admin_token) < 10 then
    raise exception 'unauthorized' using errcode = '42501';
  end if;

  select p.id into v_partner_id
    from partners p
    where p.slug = p_partner_slug
      and p.active = true
      and p.admin_token = p_admin_token;

  if v_partner_id is null then
    raise exception 'unauthorized' using errcode = '42501';
  end if;

  return query
    select s.id, s.token, s.policy_ref, s.status, s.stage1_result,
           s.stage2_result, s.overall_result, s.device_brand,
           s.device_model, s.language, s.created_at
      from sessions s
      where s.partner_id = v_partner_id
      order by s.created_at desc
      limit least(p_limit, 100);
end;
$$;

-- ------------------------------------------------------------
-- 4. Grant execution to anon (callable with publishable key)
-- ------------------------------------------------------------
grant execute on function admin_create_session(text, text, text, text) to anon;
grant execute on function admin_list_sessions(text, text, int) to anon;
