-- schema-fix-16.sql — TAC (Type Allocation Code) catalogue: exact make/model from the IMEI.
--
-- WHY: the client can only guess the model from screen dimensions, and devices that share
-- dimensions are indistinguishable — an iPhone could only ever be reported as
-- "iPhone 17 Pro Max / 16 Pro Max". The first 8 digits of the IMEI (the TAC) identify the
-- exact device. Melanie asked for the actual make and model (2026-07-28).
--
-- SOURCE: github.com/MoazEb/tac-database (MIT licence), snapshot 2026-07-23.
-- Only the 93,042 rows that actually name a model are loaded; the remaining ~161k
-- brand-only rows behave identically to a miss (both fall back to the screen-size range),
-- so they buy nothing and cost load time.
--
-- CONTRACT: this is ADVISORY EVIDENCE. It is never an input to pass/fail. The exact model
-- is DISPLAYED only when the edge function marks it high-confidence, which requires all
-- three of: the catalogue named a model, the IMEI's Luhn check digit passed, and the
-- catalogue brand does not contradict the client's detected brand. Anything less shows the
-- honest range. A wrong exact model on an enrolment record is worse than a range, because
-- the insurer relies on it at claim time.
--
-- Applied by hand to the live project on 2026-07-28; recorded here so the repo can
-- reproduce the schema. Safe to re-run.

insert into schema_migrations (version) values ('16-tac-catalogue')
  on conflict do nothing;

-- tac   : 8 digits, zero-padded (leading zeros are significant — char(8), not a number).
-- brand : manufacturer as the catalogue spells it ("Apple", "Samsung", "OPPO", "vivo").
-- model : full marketing name, which already leads with the make in 99% of rows
--         ("Samsung Galaxy S26 Ultra"). NULL is allowed but no NULL rows are loaded.
create table if not exists tac_catalogue (
  tac   char(8) primary key,
  brand text not null,
  model text
);

-- No policies = service-role only, matching rate_limits_text (schema-fix-14). The
-- edge function reads this with the service-role key; anon must never see it.
alter table tac_catalogue enable row level security;

-- Data load is out-of-band: ~93k rows from the CSV, in 5 chunks of
-- `insert into tac_catalogue (tac,brand,model) values (...) on conflict (tac) do nothing;`
-- Re-runnable. Refresh by regenerating from the upstream CSV and re-pasting.

-- 68 rows carry a placeholder model of the form '<Brand> Unknown' (defunct 2000s brands:
-- Suncorp, Vk Mobile, ...). Demote them to brand-only so they can never reach high
-- confidence and render literally as "Suncorp Unknown" on an enrolment record.
update tac_catalogue set model = null where model = brand || ' Unknown';

-- Advisory columns on the session. device_brand / device_model are left alone: those stay
-- the CLIENT's claim (user-agent + screen sniffing). tac_* is the CATALOGUE's claim, from
-- the IMEI. Keeping both is the point — a disagreement is itself evidence, and overwriting
-- the client's claim would destroy the audit trail.
alter table sessions
  add column if not exists tac_brand      text,
  add column if not exists tac_model      text,
  add column if not exists tac_confidence text,   -- 'high' | 'low'
  add column if not exists tac_reason     text;   -- ok | brand_only | tac_not_found |
                                                  -- imei_checksum_failed | brand_conflict |
                                                  -- lookup_error
