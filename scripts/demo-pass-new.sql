-- Create one BD demo pass and print the address its QR code must encode.
--
-- Run in the Supabase SQL editor, after schema-fix-17.sql. The code is printed ONCE: only its
-- sha256 is stored, so copy the qr_url from the result straight away. If it is lost, switch
-- that pass off and create a new one.
--
-- Before running, replace CHANGE-ME with the pass's label: lowercase letters, digits and
-- dashes, 2-40 characters, e.g. bd-jane or expo-kl-2026-11. The placeholder fails the label
-- check on purpose, so this cannot run unedited.
--
-- Optional, per pass: per_hour (default 6), per_day (default 20), session_hours (default 4),
-- language ('en' | 'ms'), valid_until (default none) — add them to the column list below.

with c as (
  select encode(extensions.gen_random_bytes(16), 'hex') as code
), ins as (
  insert into demo_links (partner_id, label, code_hash)
  select p.id, 'CHANGE-ME', encode(sha256(convert_to(c.code, 'UTF8')), 'hex')
    from partners p, c
   where p.slug = 'nexacore-bd-demo'
  returning label
)
select ins.label, 'https://demo.nexcheck.io/start/#c=' || c.code as qr_url
  from ins, c;

-- Switch a pass off (or back on):   update demo_links set active = false where label = 'bd-jane';
-- Change its limits:               update demo_links set per_day = 40 where label = 'bd-jane';
-- See its demos:                   select policy_ref, status, overall_result, created_at
--                                    from sessions where demo_link_id =
--                                      (select id from demo_links where label = 'bd-jane')
--                                   order by created_at desc;
