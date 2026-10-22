-- Tests for schema-fix-17 (BD demo passes).
--
-- Run against a THROWAWAY database that has schema.sql + every schema-fix applied — never the
-- live project. Everything runs in one transaction and is rolled back, so it can be re-run.
-- A failed assert aborts with its message; success prints "demo-pass tests: ALL PASSED".
--
--   psql -h 127.0.0.1 -p 55432 -U postgres -v ON_ERROR_STOP=1 -f scripts/demo-pass-test.sql

begin;

insert into demo_links (partner_id, label, code_hash, per_hour, per_day)
select id, 'test-pass', encode(sha256(convert_to('test-code-0123456789abcdef', 'UTF8')), 'hex'), 2, 3
  from partners where slug = 'nexacore-bd-demo';

create function pg_temp.expect_error(p_sql text, p_message text) returns void
language plpgsql as $$
declare
  v_succeeded boolean := false;
begin
  begin
    execute p_sql;
    v_succeeded := true;
  exception
    when others then
      if sqlerrm <> p_message then
        raise exception 'expected error "%" but got "%" from: %', p_message, sqlerrm, p_sql;
      end if;
  end;
  if v_succeeded then
    raise exception 'expected error "%" but the call succeeded: %', p_message, p_sql;
  end if;
end;
$$;

do $$
declare
  c   constant text := 'test-code-0123456789abcdef';
  t1  text;
  t2  text;
  s   record;
  got jsonb;
begin
  -- The migration created the BD partner, with its own admin token.
  assert exists (select 1 from partners where slug = 'nexacore-bd-demo' and active
                   and admin_token like 'nxa\_%' and name = 'Nexacore Demo'),
         'BD partner exists with its own admin token';

  -- 1. A valid code mints a fresh session under the BD partner.
  t1 := demo_start_session(c);
  assert t1 is not null and length(t1) >= 32, 'token returned';
  select se.status, se.policy_ref, se.language, se.expires_at, se.demo_link_id, p.slug
    into s
    from sessions se join partners p on p.id = se.partner_id
   where se.token = t1;
  assert s.slug = 'nexacore-bd-demo', 'session belongs to the BD partner';
  assert s.status = 'created', 'session starts as created';
  assert s.policy_ref like 'demo-test-pass-%', 'policy_ref tags the pass: ' || s.policy_ref;
  assert s.language = 'en', 'language comes from the pass';
  assert s.expires_at between now() + interval '3 hours 59 minutes' and now() + interval '4 hours 1 minute',
         'session lives 4 hours, not the 72h default';
  assert s.demo_link_id = (select id from demo_links where label = 'test-pass'), 'session linked to its pass';
  assert exists (select 1 from audit_log a join sessions se on se.id = a.session_id
                  where se.token = t1 and a.event_type = 'session_created_via_demo_link'
                    and a.event_data->>'demo_link' = 'test-pass'),
         'creation is audited';

  -- 2. The next tap gets a different session.
  t2 := demo_start_session(c);
  assert t2 <> t1, 'each tap is a new session';

  -- 3. Hourly cap (2) reached.
  perform pg_temp.expect_error(format('select demo_start_session(%L)', c), 'demo_limit_reached');

  -- 4. An hour later the hourly cap frees up, but the daily cap (3) still counts them.
  update sessions set created_at = now() - interval '2 hours' where token in (t1, t2);
  perform demo_start_session(c);
  perform pg_temp.expect_error(format('select demo_start_session(%L)', c), 'demo_limit_reached');
  update sessions set created_at = now() - interval '25 hours'
   where demo_link_id = (select id from demo_links where label = 'test-pass');
  perform demo_start_session(c);  -- a day later it works again

  -- 5. Bad codes all look the same to the caller.
  perform pg_temp.expect_error('select demo_start_session(''wrong-code-0123456789abcdef'')', 'demo_link_invalid');
  perform pg_temp.expect_error('select demo_start_session(''short'')', 'demo_link_invalid');
  perform pg_temp.expect_error('select demo_start_session(null)', 'demo_link_invalid');
  perform pg_temp.expect_error(format('select demo_start_session(%L)', repeat('a', 200)), 'demo_link_invalid');

  -- 6. Switched-off pass, expired pass, switched-off partner.
  update demo_links set active = false where label = 'test-pass';
  perform pg_temp.expect_error(format('select demo_start_session(%L)', c), 'demo_link_invalid');
  update demo_links set active = true, valid_until = now() - interval '1 minute' where label = 'test-pass';
  perform pg_temp.expect_error(format('select demo_start_session(%L)', c), 'demo_link_invalid');
  update demo_links set valid_until = null where label = 'test-pass';
  update partners set active = false where slug = 'nexacore-bd-demo';
  perform pg_temp.expect_error(format('select demo_start_session(%L)', c), 'demo_link_invalid');
  update partners set active = true where slug = 'nexacore-bd-demo';

  -- 7. The minted session works with the existing customer RPC.
  got := session_get(t1);
  assert got->'partner'->>'name' = 'Nexacore Demo', 'session_get serves the new session: ' || got::text;

  -- 8. The pass-creation snippet's placeholder label cannot be inserted.
  perform pg_temp.expect_error(
    $q$insert into demo_links (partner_id, label, code_hash)
       select id, 'CHANGE-ME', 'x' from partners where slug = 'nexacore-bd-demo'$q$,
    'new row for relation "demo_links" violates check constraint "demo_links_label_check"');

  raise notice 'demo-pass assertions 1-8 passed';
end;
$$;

-- 9. What the anonymous (browser) role may and may not do.
set local role anon;
select 'anon can mint' as check, length(demo_start_session('test-code-0123456789abcdef')) >= 32 as ok;
do $$
begin
  perform 1 from demo_links;
  raise exception 'anon could read demo_links';
exception when insufficient_privilege then null;
end;
$$;
do $$
begin
  perform 1 from sessions;
  raise exception 'anon could read sessions';
exception when insufficient_privilege then null;
end;
$$;
reset role;

do $$ begin raise notice 'demo-pass tests: ALL PASSED'; end; $$;

rollback;
