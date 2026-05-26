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

There is no build step. Both files are hand-edited HTML/CSS/JS, deployed by pushing to `main`.

| File | What it is |
|---|---|
| `index.html` | Customer flow. Single page, 8 screens controlled by `goToStep(n)`. ~2,800 lines (CSS + JS inline). |
| `admin.html` | Partner dashboard. Token-gated, lists sessions, click-through detail. ~1,000 lines. |

**Local preview:** open the file directly. Both will run in preview mode without a session token. To test against a real session, append `#s=<token>` to the URL.

**Deploy:** `git push origin main`. GitHub Pages picks it up in ~30s. There is no staging environment yet.

---

## 3. The two edge functions

Both live in the repo root as `.ts` files but are deployed to Supabase. There is **no build pipeline** — the file is uploaded as-is into the Supabase dashboard or via the CLI.

| File | Deployed name | Purpose |
|---|---|---|
| `edge-function-upload-and-process.ts` | `smart-handler` | Receives IMEI screenshots and Stage 2 photos. Runs Vision OCR for IMEI, Gemini photo analysis for damage detection, applies rejection rules, writes to storage + DB + audit log. |
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
| `schema-fix-01.sql` … `schema-fix-11.sql` | Migrations layered in order |

`schema_migrations` table tracks applied versions (created in `schema-fix-02.sql`).

**Run order on a fresh DB:**

```bash
psql "$DATABASE_URL" -f schema.sql
for f in schema-fix-*.sql; do psql "$DATABASE_URL" -f "$f"; done
```

⚠️ `schema-fix-08-diag.sql` is a temporary diagnostic — skip on a fresh setup. The consolidation work in `CLEANUP-AUDIT.md` §1.2 (a half-day task) collapses all this into one baseline file.

**Schema browser:** Supabase Dashboard → Table Editor.

---

## 5. Everyday workflow

### To change the customer flow
1. Edit `index.html`
2. Open the file locally to smoke-test (`#s=<a real token>` to test against a live session)
3. `git commit && git push` — GitHub Pages updates automatically

### To change an edge function
1. Edit `edge-function-*.ts`
2. Commit so source of truth stays in git
3. Redeploy to Supabase (dashboard paste or CLI)
4. Run an end-to-end check on your phone to confirm

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
3. **Do task #47** (UA-CH device detection) — 30 min, visible win, low-risk first commit.
4. **§1.2 schema consolidation** — half day. Establishes the migrations folder pattern.
5. **§2.3 + §2.4** — extract `_shared/` and split `smart-handler` into focused modules. Half day. Unblocks unit tests.
6. **§5 unit tests** for `rejection-rules` and `extractImei` — covers the regression cases we've already hit.
7. **§2.1** split `index.html` before any second front-end contributor joins.
8. **Task #67** — i18n (en + ms). Day-one MVP requirement, not yet built.

---

## 7. Production URLs

| Surface | URL |
|---|---|
| Customer flow | `https://nexacore-my.github.io/device-check/#s=<token>` |
| Admin dashboard | `https://nexacore-my.github.io/device-check/admin.html` |
| Supabase project | `https://rysbsztwxjwndwebguuj.supabase.co` |
| smart-handler endpoint | `https://rysbsztwxjwndwebguuj.supabase.co/functions/v1/smart-handler` |
| admin-detail endpoint | `https://rysbsztwxjwndwebguuj.supabase.co/functions/v1/admin-detail` |

---

## 8. Who to ask

- **Product / customer / commercial questions** — Melanie.
- **Anything code-shaped you're unsure about** — the audit doc has the rationale for most of the structural decisions. If it doesn't answer it, ask Melanie and we'll capture the answer in this runbook.
