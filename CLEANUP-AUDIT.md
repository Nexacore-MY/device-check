# Device Check — Cleanup Audit

Prepared for engineer handoff. Each item lists the problem, evidence, and a recommended action. Items are grouped by category and ranked by impact within each group.

---

## 1. Repository hygiene

### 1.1 Dead duplicate HTML files (tracked in git)
**Files:** `device-check-v2.html`, `device-check-v3.html`, `device-check-v4.html`, `indexv2.html`, `nexacore-device-check.html`, `index.html.bak`

`v2` and `v3` are byte-identical (`diff -q` returns nothing). `v4` is the older "working version" that `PROTOTYPE-STATUS.md` still points to; `index.html` (the GH-Pages copy) is now the canonical file and has diverged. `index.html.bak` is 790 lines different from `index.html`. None of these are referenced anywhere else.

**Action:** delete all six from the working tree, `git rm` them, commit. The repo drops from 25 tracked files to 19 and from ~1.9 MB to <500 KB.

### 1.2 Stale schema files
**Files:** `schema.sql` (titled "Phase 1"), `schema-fix-01.sql` through `schema-fix-11.sql` (with `schema-fix-08-diag.sql` instead of `08`)

There is no way to reproduce the production DB from one file. A new engineer would need to apply 12 files in order, and `schema-fix-01.sql` does not insert into `schema_migrations` (the tracking table is created in 02). `schema-fix-08-diag.sql` is described in its own header as a "temporary wide-open policy" for diagnosis.

**Action:** one of —
- (a) Snapshot current prod schema with `pg_dump --schema-only` into `db/baseline.sql`, then start a numbered `db/migrations/` folder for anything new. Delete `schema-fix-08-diag.sql`. Move `schema.sql` and `schema-fix-*.sql` into an `db/_legacy/` folder so the history is preserved but the canonical entry point is unambiguous.
- (b) Adopt Supabase CLI migrations (`supabase/migrations/`) — same outcome, official tooling.

### 1.3 .DS_Store at repo root
Present locally, correctly listed in `.gitignore`. Not tracked. No action needed; flagged for awareness.

### 1.4 Secrets posture (good — no action)
Verified via `git log --all`: `gcp-vision-key.json`, `.env`, and `admin-config.js` have never been committed. `.gitignore` is correctly scoped. `admin-config.js` contains a live admin token in plaintext — acceptable for local-only use but the engineer should know it exists and rotate it before any other person works on the repo.

---

## 2. Code structure

### 2.1 index.html is a 2,822-line monolith
- ~1,355 lines of CSS (lines 9–1,364)
- ~1,450 lines of JS (lines 1,366–2,820)
- 8 screens interleaved through the HTML body
- 37 inline `style="..."` attributes scattered through the markup
- `nxShowBanner` (lines 1,433–1,473) writes ~1,500 chars of `cssText` dynamically on every call instead of toggling a class

**Action (engineer call):** the cheap win is to split into `index.html` + `styles.css` + `app.js` and convert the 37 inline styles into CSS classes. The deeper refactor is to break the 8 screens into per-screen modules — worth doing before a second engineer starts touching this in parallel.

### 2.2 admin.html is a 1,019-line monolith
Same shape as index.html — HTML + CSS + JS in one file. Lower priority because it's internal-only, but the same split would help.

### 2.3 Edge function duplication
`edge-function-upload-and-process.ts` (587 lines) and `edge-function-admin-detail.ts` (139 lines) both inline:
- `CORS_HEADERS` constant
- `json()` response helper
- `createClient(SUPABASE_URL, SERVICE_ROLE)` boilerplate
- env-var reads for `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY`

**Action:** extract a `_shared/` folder (Supabase Edge convention) with `cors.ts`, `response.ts`, `supabase.ts`. Both functions import from there.

### 2.4 smart-handler does too much
`edge-function-upload-and-process.ts` handles: GCP JWT signing, base64 chunking, Vision OCR, Luhn check, IMEI extraction (3 strategies), Gemini call, prompt construction, rejection rule engine, storage upload, rate limit checks, RPC quota check, DB writes to `sessions`/`photos`/`audit_log`, and the HTTP handler. One file, no tests.

**Action:** split into modules under `supabase/functions/smart-handler/`:
- `gcp-auth.ts` — JWT exchange + token cache
- `vision-ocr.ts` — Vision call + Luhn + `extractImei`
- `gemini-analysis.ts` — Vertex call + prompt
- `rejection-rules.ts` — `evaluatePhotoAnalysis` (pure function, easy to unit test)
- `index.ts` — HTTP handler that orchestrates the above

The rejection-rules module specifically is a pure function operating on a typed input — it's the highest-value file to extract because it's where regressions hurt customers and the only file that has needed touch-ups every week.

### 2.5 Magic strings repeated everywhere
Bucket names (`imei_screenshots`, `condition_photos`), photo slots (`imei` / `screen` / `back`), session statuses (`created`, `stage1_complete`, etc.), rejection reasons (`fold_phone_closed`, `pre_existing_damage`, …) appear as bare strings in multiple files. Frontend and backend must stay in sync by hand.

**Action:** a shared `constants.ts` (or `types/contracts.ts`) consumed by both edge functions and — ideally — generated into a small JS object the HTML pages import. Even a hand-mirrored `nx-constants.js` would be safer than the current pattern.

---

## 3. Bugs and small fixes (already queued, summarised for context)

These are on the existing punch list (#47–#56) but listed here for the engineer:

- **#47 — Device detection broken on modern Chrome/Android.** `identifyDevice()` (index.html:1760) regex-matches `navigator.userAgent`; Chrome's UA reduction now sends `Mozilla/5.0 (Linux; Android 14; K)` — no brand, no model. `extractAndroidModel()` (line 1799) expects a `Build/` token Chrome no longer ships. Fix with `navigator.userAgentData.getHighEntropyValues(['model','platform'])` and regex fallback for Safari/Firefox.
- **#53 — `audit_log.ip_address` and `audit_log.user_agent` never populated.** The schema defines them; the edge function never sets them. Cheap fix in `smart-handler`.
- **#54 — Submit button text not restored on RPC failure.** `submitStage2()` in index.html.
- **#55 — Banner missing `aria-live="polite"`.** Accessibility nit, add when refactoring the banner per §2.1.
- **#56 — Signed URL expiry for admin views is 1 hour.** `edge-function-admin-detail.ts:35` — drop to 15 min before any external admin gets credentials.

---

## 4. Documentation drift

### 4.1 PROTOTYPE-STATUS.md points at the wrong file
Lines 8–10 state "**Working version:** `device-check-v4.html`" and "GitHub Pages deployment copy: `index.html` (synced with v4)". After §1.1 deletes the v4 file, this paragraph needs to read: "**Working version:** `index.html` (canonical, deployed to GitHub Pages)."

### 4.2 schema.sql header is misleading
Says "Phase 1" with no pointer to migrations 01–11. After §1.2 consolidation this resolves automatically.

---

## 5. Verification checklist for the engineer

Before declaring cleanup done:

1. `git status` clean.
2. `git ls-files | wc -l` shows the expected smaller count.
3. Customer flow loads at the GH-Pages URL with no console errors and completes a full check (IMEI + 2 photos + Done).
4. Admin dashboard loads, lists sessions, opens detail, IMEI screenshot + photo signed URLs resolve.
5. New engineer can stand up a fresh Supabase project from `db/baseline.sql` alone (or `supabase db reset` if §1.2 (b) was chosen) and the smart-handler deploys against it without manual SQL.
6. Unit tests exist for `rejection-rules.ts` and `extractImei()` covering at minimum the cases captured in tasks #44 (label digit stitching), #45 (fold-closed), and #46 (iPhone 17 Pro back / mirror flip).

---

## Suggested order of work

1. **§1.1** — delete dead files (15 min, no risk).
2. **§1.2** — schema consolidation (half day; once done, all future schema changes go through migrations folder).
3. **§2.3 + §2.4** — extract `_shared/` and split smart-handler (half day; unblocks unit testing).
4. **§3 #47** — UA-CH device detection (30 min, visible win in dashboard).
5. **§2.1** — split index.html into HTML/CSS/JS (half day; do before bringing in any second front-end contributor).
6. **§2.5** — shared constants (1–2 hrs after the splits).
7. **§4** — update docs to match the new layout.
8. **§3 #53–#56** — the small bug fixes, batched.

Everything else (§2.2 admin split, §5 unit tests) is a fast-follow.
