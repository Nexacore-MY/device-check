# Device Check — Engineer Runbook

First-day setup, daily workflow, and deploy steps. Read `PROTOTYPE-STATUS.md` first for what the product is.

---

## 0. What you'll be given

From Melanie (out-of-band, via password manager — not email/Slack):

- GitHub collaborator invite to the `device-check` repo
- Supabase team invite (project `rysbsztwxjwndwebguuj`, Singapore region)
- Google Cloud IAM grant on the Vertex AI / Vision project
- Three local-only files (gitignored, **never commit these**):
  - `.env` — Supabase URL + service role key
  - `gcp-vision-key.json` — Google Cloud service account JSON
  - `admin-config.js` — admin token for the partner dashboard

If the admin token has been rotated for handover, the value in `admin-config.js` is yours; the old one is dead.

---

## 1. First-day setup (~30 min)

```bash
# 1. Clone
git clone git@github.com:nexacore-my/device-check.git
cd device-check

# 2. Drop the three gitignored files into the repo root:
#    .env
#    gcp-vision-key.json
#    admin-config.js

# 3. Confirm they are ignored, not staged
git status   # should be clean

# 4. Install Supabase CLI if you don't have it
brew install supabase/tap/supabase   # macOS
# (or see https://supabase.com/docs/guides/cli)

# 5. Link the CLI to the project (uses your Supabase login)
supabase login
supabase link --project-ref rysbsztwxjwndwebguuj
```

You should now be able to:
- Open `index.html` directly in a browser (preview mode — no session, no backend writes)
- Open `admin.html` directly in a browser, paste the admin token, see live sessions
- Run `supabase functions list` and see `smart-handler` and `admin-detail`

---

## 2. The two HTML files

There is no build step. Both files are hand-edited HTML/CSS/JS.

| File | What it is |
|---|---|
| `index.html` | Customer flow. Single page, 9 screens controlled by `goToStep(n)`. 3,023 lines (CSS + JS inline). |
| `admin.html` | Partner dashboard. Token-gated, lists sessions, click-through detail. 1,028 lines. |

**Local preview:** open the file directly. Both will run in preview mode without a session token. To test against a real session, append `#s=<token>` to the URL.

### ⚠️ Deploy — read this before you push

The live demo is **Vercel**, served at **`demo.nexcheck.io`**, built from branch **`aia-qr-demo`**:

```bash
git checkout aia-qr-demo   # the live branch — NOT main
vercel --prod              # uploads the working dir; .vercelignore keeps secrets/backend out
```

**`git push origin main` does not deploy the live demo, and shipping `main` is actively harmful.**
`main` is the **old pre-QR build**: mirror photo flow still present, no QR hand-off to a second
phone, no TAC make/model. GitHub Pages (`nexacore-my.github.io/device-check`) still serves that
old build from `main` — putting it in front of an insurance prospect shows the wrong product.

`.vercelignore` deliberately excludes `admin.html`, the `.ts` edge functions, `*.sql` and `*.md`
from the upload — the Vercel deploy is the **customer app only**. The admin dashboard is not
published; open `admin.html` locally (§1).

There is no staging environment yet.

---

## 3. The two edge functions

Both live in the repo root as `.ts` files but are deployed to Supabase. There is **no build pipeline** — the file is uploaded as-is into the Supabase dashboard or via the CLI.

| File | Deployed name | Purpose |
|---|---|---|
| `edge-function-upload-and-process.ts` | `smart-handler` | Receives IMEI screenshots and Stage 2 photos. Runs Vision OCR for IMEI, the TAC make/model lookup (advisory, §4.1), Gemini photo analysis for damage detection, applies rejection rules, writes to storage + DB + audit log. |
| `edge-function-admin-detail.ts` | `admin-detail` | Returns one session + signed Storage URLs (15-min expiry) for the admin dashboard detail view. |

### Deploying via Supabase Dashboard (current workflow)

1. Supabase Dashboard → Edge Functions → click the function name.
2. Paste the full file contents into the editor.
3. Click **Deploy**.
4. After first deploy, check the function's settings and **disable "Verify JWT"** — both functions authenticate via custom tokens, not Supabase auth.

### Deploying via CLI (recommended once you're set up)

```bash
# Smart-handler
supabase functions deploy smart-handler \
  --no-verify-jwt \
  --import-map ./supabase/import_map.json

# (Equivalent for admin-detail)
```

The CLI workflow is what the engineer should set up properly — see §6.

### Edge function secrets (already configured in production)

Set via Supabase Dashboard → Edge Functions → Settings → Secrets:

- `SUPABASE_URL` — auto-injected by Supabase
- `SUPABASE_SERVICE_ROLE_KEY` — auto-injected
- `GCP_VISION_CREDENTIALS` — the full `gcp-vision-key.json` contents pasted as one JSON string

Test that secrets are set with `supabase secrets list`.

---

## 4. Database

| File | Use |
|---|---|
| `schema.sql` | Phase 1 baseline (tables, indexes, RLS enable) |
| `schema-fix-01.sql` … `schema-fix-16.sql` | Migrations layered in order. 17 files with `schema.sql`; there is no plain `08` — it is `08-diag`. |

`schema_migrations` table tracks applied versions (created in `schema-fix-02.sql`).

Tables: `partners`, `sessions`, `diagnostics`, `photos`, `webhook_deliveries`, `audit_log`,
`schema_migrations`, `rate_limits`, `rate_limits_text`, `tac_catalogue`.

**Run order on a fresh DB:**

```bash
psql "$DATABASE_URL" -f schema.sql
for f in schema-fix-*.sql; do psql "$DATABASE_URL" -f "$f"; done
```

⚠️ **These files alone do NOT give you a working DB.** Two gaps:

- **`schema-fix-16.sql` creates the `tac_catalogue` table and loads ZERO rows.** The 93,042-row
  data load is deliberately out-of-band (§4.1). A fresh DB built from the files above has an
  **empty catalogue**: every TAC lookup misses, **nothing errors**, no log line fires, and the
  make/model feature silently does nothing forever — the flow just keeps showing the screen-size
  range. Load the data before you test, and verify with a row count.
- `schema-fix-08-diag.sql` is a temporary diagnostic (its own header calls it a "temporary
  wide-open policy") — skip it on a fresh setup.

The consolidation work in `CLEANUP-AUDIT.md` §1.2 (a half-day task) collapses all this into one baseline file.

**Schema browser:** Supabase Dashboard → Table Editor.

### 4.1 Loading / refreshing the TAC catalogue

`tac_catalogue` maps the first 8 digits of the IMEI — the Type Allocation Code — to a make and
model, so the enrolment record carries the exact device instead of the client's screen-size guess.
**Advisory only: it is never an input to pass/fail.**

Source: **`github.com/MoazEb/tac-database`** — **MIT licence**, snapshot **2026-07-23**. Keep the
attribution with the data.

Only the rows that actually name a model are loaded: **93,042**. The ~161k brand-only rows behave
identically to a miss (both fall back to the screen-size range), so they buy nothing and cost load
time.

To refresh from upstream:

1. Pull the current CSV from the upstream repo.
2. Filter to model-bearing rows, keep `tac,brand,model`, and zero-pad the TAC to 8 characters —
   leading zeros are significant, the column is `char(8)`, not a number.
3. Load it, either way (both are re-runnable):
   - `\copy` the CSV into a staging table, then
     `insert into tac_catalogue ... on conflict (tac) do nothing;`
   - or paste `insert into tac_catalogue (tac,brand,model) values (...) on conflict (tac) do nothing;`
     chunks into the SQL Editor. The original load was 5 chunks.
4. Re-run the placeholder demotion at the foot of `schema-fix-16.sql`:
   `update tac_catalogue set model = null where model = brand || ' Unknown';`
   (68 defunct-brand rows that would otherwise render as "Suncorp Unknown" on a record.)
5. Verify: `select count(*) from tac_catalogue;` should be ~93k, and the TAC of a phone you have
   to hand should resolve. A silent miss is indistinguishable from a missing load — check the count.

### Applying a new migration to production

1. Add `schema-fix-NN.sql` to the repo root with the next sequential number, headed by `insert into schema_migrations (version) values ('NN-short-name') on conflict do nothing;`
2. Commit and push.
3. Supabase Dashboard → SQL Editor → New query → paste the file contents → Run.
4. Confirm by running `select * from schema_migrations order by applied_at desc limit 5;` — your new version should appear at the top.

There is no automatic apply step. Production DB changes are still manual paste-and-run.

---

## 5. Everyday workflow

### To change the customer flow
1. Edit `index.html` on `aia-qr-demo`
2. Open the file locally to smoke-test (`#s=<a real token>` to test against a live session)
3. `git commit`, then `vercel --prod` (§2). **Committing/pushing does not deploy anything.**

### To change an edge function
1. Edit `edge-function-*.ts`
2. Commit so source of truth stays in git
3. Redeploy to Supabase (dashboard paste or CLI)
4. Run an end-to-end check on your phone to confirm

**Important: source-of-truth drift risk.** Production runs the version pasted into the Supabase dashboard editor. The repo's `.ts` files are only the source-of-truth if every change is followed by a paste-and-deploy. If you change the `.ts`, commit it, but forget to paste into Supabase, production keeps running the old code and the repo lies. Always deploy and verify within the same work session.

### To change the schema
1. Add `schema-fix-NN.sql` (next number in sequence)
2. Apply via Supabase Dashboard → SQL Editor (paste + Run)
3. Commit the file
4. Note: this whole pattern is queued for refactor — see `CLEANUP-AUDIT.md` §1.2.

### To add a new partner (currently)
SQL insert into `partners` table. There is no UI for this yet. Required fields: `name`, `slug`, `api_key` (generate via `'nx_' || encode(gen_random_bytes(16), 'hex')`), `admin_token` (similarly), `webhook_url`, `webhook_secret`.

---

## 6. What to do first (engineer's first-week recommendation)

The codebase is pilot-ready but messy. `CLEANUP-AUDIT.md` is the full punch list. Recommended order:

1. **Read** `PROTOTYPE-STATUS.md` and this runbook.
2. **Set up the Supabase CLI workflow** so edge function deploys go through `supabase functions deploy` instead of dashboard paste.
3. **Do task #47** (UA-CH device detection) — 30 min, low-risk first commit. Partly superseded by
   the TAC lookup (which now names the exact model when the IMEI resolves), but still the fallback
   whenever the TAC misses or is low-confidence. See `CLEANUP-AUDIT.md` §3.
4. **§1.2 schema consolidation** — half day. Establishes the migrations folder pattern.
5. **§2.3 + §2.4** — extract `_shared/` and split `smart-handler` into focused modules. Half day. Unblocks unit tests.
6. **§5 unit tests** for `rejection-rules` and `extractImei` — covers the regression cases we've already hit.
7. **§2.1** split `index.html` before any second front-end contributor joins.
8. **Task #67** — i18n (en + ms). Day-one MVP requirement, not yet built.

---

## 7. Production URLs

| Surface | URL |
|---|---|
| **Customer flow (live)** | `https://demo.nexcheck.io/#s=<token>` — Vercel, branch `aia-qr-demo` |
| Admin dashboard | Not published. Open `admin.html` locally (excluded via `.vercelignore`). |
| Supabase project | `https://rysbsztwxjwndwebguuj.supabase.co` |
| smart-handler endpoint | `https://rysbsztwxjwndwebguuj.supabase.co/functions/v1/smart-handler` |
| admin-detail endpoint | `https://rysbsztwxjwndwebguuj.supabase.co/functions/v1/admin-detail` |

⚠️ **`https://nexacore-my.github.io/device-check/` (and `/admin.html`) is GitHub Pages serving
branch `main` — the old pre-QR build.** It is not the live demo. Never send it to a prospect.

⚠️ **The admin dashboard still mints links against that old base.** `admin.html:525` hardcodes
`CHECK_URL_BASE: 'https://nexacore-my.github.io/device-check/'` and line 626 builds the customer
link from it, so a session created in the dashboard points at the stale build. Until that constant
is changed to `https://demo.nexcheck.io/`, **swap the host by hand before sending any demo link.**

---

## 8. Who to ask

- **Product / customer / commercial questions** — Melanie.
- **Anything code-shaped you're unsure about** — the audit doc has the rationale for most of the structural decisions. If it doesn't answer it, ask Melanie and we'll capture the answer in this runbook.
