# AIA Demo: Reliability/Rate-limit Fix + QR Hand-off — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the live MVP demo AIA-ready — port the prod reliability/quota fix, relax the per-IP rate limit for a two-phone demo, and add a QR second-phone hand-off.

**Architecture:** Backend = Deno edge function (`edge-function-upload-and-process.ts`) + `schema-fix-NN.sql` migrations on the live MVP Supabase. Frontend = single static `index.html`. Parts A+B ship as one backend deploy; Part C ships with `index.html`.

**Tech Stack:** Deno (edge fn), Postgres/Supabase (RPCs), vanilla JS/HTML (customer app), `qrcode-generator` (vendored, MIT) for the QR.

**Verification reality:** the MVP has **no test harness**. Per-task checks are `deno check <file>` for the edge fn, manual SQL review/`psql` dry-run, and `grep` confirmation; the whole thing is validated end-to-end by a **manual two-phone test over HTTPS**. Part A is a byte-faithful port of `Device-check-prod` commits `0763506`/`626772b` (already parity-tested there).

**Branch:** `aia-qr-demo` only. Never touch `main`. Commit after each task.

---

## Task Group A — Reliability & quota fix (port from prod)

### Task A1: Raise the Vision/Gemini timeouts

**Files:** Modify `edge-function-upload-and-process.ts:460` (Vision) and `:508` (Gemini).

- [ ] **Step 1: Edit the timeouts.** Change `setTimeout(() => controller.abort(), 7000)` → `10000` (Vision, ~:460) and `setTimeout(() => controller.abort(), 12000)` → `22000` (Gemini, ~:508). Add a brief comment: `// raised to cover Gemini's real 13-14s slow tail (see prod 0763506)`.
- [ ] **Step 2: Verify.** `grep -nE 'abort\(\), (10000|22000)' edge-function-upload-and-process.ts` → expect both lines.
- [ ] **Step 3: Commit.** `git add edge-function-upload-and-process.ts && git commit -m "fix(edge): raise Vision 7->10s, Gemini 12->22s timeouts"`

### Task A2: Add `session_refund_upload_quota` RPC

**Files:** Create `schema-fix-13.sql`.

- [ ] **Step 1: Create the migration** (port of `Device-check-prod/supabase/migrations/20260616000000_refund_upload_quota.sql`; columns `upload_count_imei`/`upload_count_photo` already exist from schema-fix-09):

```sql
-- schema-fix-13.sql — session_refund_upload_quota: give back a consumed upload slot.
-- session_check_upload_quota (fix-09) increments on EVERY call, incl. infra failures
-- (Vision/Gemini timeout). Combined with the timeout, a slow backend burns the quota
-- and the link locks before the user finishes. The edge fn now refunds the slot on
-- infra failure so only real attempts count. Service-role only.
create or replace function session_refund_upload_quota(p_token text, p_kind text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_kind = 'imei' then
    update sessions set upload_count_imei = greatest(upload_count_imei - 1, 0) where token = p_token;
  else
    update sessions set upload_count_photo = greatest(upload_count_photo - 1, 0) where token = p_token;
  end if;
end; $$;
revoke all on function session_refund_upload_quota(text, text) from public, anon, authenticated;
grant execute on function session_refund_upload_quota(text, text) to service_role;
```

- [ ] **Step 2: Verify SQL parses.** Review against `schema-fix-09.sql` column names; if a local Postgres is handy, `psql -f schema-fix-13.sql` on a scratch DB. (Deploy to live Supabase happens in the Deploy task, not here.)
- [ ] **Step 3: Commit.** `git add schema-fix-13.sql && git commit -m "feat(db): session_refund_upload_quota RPC (service-role only)"`

### Task A3: Refund the slot on infra failure (edge fn)

**Files:** Modify `edge-function-upload-and-process.ts` — the IMEI OCR-error branch (near the Vision timeout, ~:460-480) and the photo `analysis_failed` branch (~:516-535).

- [ ] **Step 1: Add a refund helper** near the top of the request handler (after `session` is resolved):

```ts
async function refundQuotaSlot(token: string, kind: string) {
  const { error } = await supabase.rpc("session_refund_upload_quota", {
    p_token: token, p_kind: kind === "imei" ? "imei" : "photo",
  });
  if (error) console.error("quota refund failed:", error);
}
```

- [ ] **Step 2: Call it in the photo infra-failure branch.** In the `if (!analysis) { ... }` block (~:518, before the `return json({ rejected:true, reason:"analysis_failed" ... }, 422)`), add: `await refundQuotaSlot(sessionToken, "photo");`
- [ ] **Step 3: Call it in the IMEI OCR-failure branch.** In the IMEI path, where OCR errored (timeout/outage → returns the `ocr_unavailable`/`analysis_failed`-equivalent), add `await refundQuotaSlot(sessionToken, "imei");` before that return. (Only the infra-error path — NOT the "OCR succeeded but found no IMEI" path, which is a genuine attempt.)
- [ ] **Step 4: Verify.** `deno check edge-function-upload-and-process.ts` (expect no type errors), and `grep -n refundQuotaSlot edge-function-upload-and-process.ts` → 3 hits (def + 2 calls).
- [ ] **Step 5: Commit.** `git commit -am "fix(edge): refund upload quota on infra failure (closes the quota-lockout)"`

---

## Task Group B — Per-IP rate-limit relaxation (demo-safe)

### Task B1: Generalize the limiter key (IP → text) + raise caps

**Files:** Create `schema-fix-14.sql`.

- [ ] **Step 1: Create the migration:**

```sql
-- schema-fix-14.sql — rate limiter keyed by a generic text key (was inet).
-- Fixes the demo killer: unknown-IP traffic was all bucketed under one global
-- "0.0.0.0" inet (10/min shared) -> behind a tunnel the whole demo shared one
-- counter. Now the edge fn passes the IP when known, else 'sess:<token>', so each
-- session gets its own bucket. Caps raised to demo-tuned values (revisit for prod).
alter table rate_limits rename column ip to rl_key;
alter table rate_limits alter column rl_key type text;

drop function if exists rl_check_and_increment(inet, int);
create or replace function rl_check_and_increment(p_key text, p_per_minute_limit int default 60)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_bucket timestamptz; v_count int;
begin
  v_bucket := date_trunc('minute', now());
  insert into rate_limits (rl_key, minute_bucket, count) values (p_key, v_bucket, 1)
    on conflict (rl_key, minute_bucket) do update set count = rate_limits.count + 1
    returning count into v_count;
  delete from rate_limits where minute_bucket < now() - interval '10 minutes';
  return v_count <= p_per_minute_limit;
end; $$;
```

- [ ] **Step 2: Verify.** Confirm the PK is `(rl_key, minute_bucket)` after the rename (Postgres keeps the PK across a column rename). Review the `drop function`/`create` for the new `text` signature.
- [ ] **Step 3: Commit.** `git add schema-fix-14.sql && git commit -m "feat(db): rate limiter keyed by text (per-session when IP unknown)"`

### Task B2: Pass a session-aware key + raise caps (edge fn)

**Files:** Modify `edge-function-upload-and-process.ts:425-432`.

- [ ] **Step 1: Replace the rate-limit block:**

```ts
// Rate-limit by IP when visible, else per-session (so a tunnel/shared-IP demo
// isn't throttled under one global bucket). Demo-tuned caps; revisit for prod.
const rlKey = ip ? ip : `sess:${sessionToken}`;
const rlLimit = ip ? 60 : 30;
const { data: ipOk } = await supabase.rpc("rl_check_and_increment", {
  p_key: rlKey, p_per_minute_limit: rlLimit,
});
if (ipOk === false) return json({ error: "Rate limit exceeded" }, 429);
```

- [ ] **Step 2: Verify.** `deno check edge-function-upload-and-process.ts`; `grep -n 'rl_check_and_increment\|p_key' edge-function-upload-and-process.ts`.
- [ ] **Step 3: Commit.** `git commit -am "fix(edge): session-aware rate key + demo-tuned caps (60/30)"`

### Task B3: Soft, non-terminal 429 copy (frontend)

**Files:** Modify `index.html` — `nxUploadViaFunction` (~:1587) and the retry-limit messages (~:2252, ~:2557).

- [ ] **Step 1: Distinguish a rate-limit 429 from a quota/terminal 429** in `nxUploadViaFunction`'s `!resp.ok` branch: if `resp.status === 429 && body.error === 'Rate limit exceeded'`, return `{ rejected: true, reason: 'rate_limited', user_message: 'Server is busy — retrying in a moment…' }` instead of throwing; for the per-session quota 429 keep the existing terminal behavior.
- [ ] **Step 2: In the callers,** treat `reason === 'rate_limited'` like `analysis_failed` (do NOT increment attempts, do NOT lock), show the soft message, and auto-retry once after ~1.5s.
- [ ] **Step 3: Verify.** `grep -n "rate_limited" index.html` → present in the upload fn + both photo/imei callers.
- [ ] **Step 4: Commit.** `git commit -am "fix(ui): soft retry on rate-limit 429 instead of 'start a new session'"`

---

## Task Group C — QR second-phone hand-off (happy-path UX)

### Task C1: Vendor a vanilla QR generator

**Files:** Create `vendor/qrcode-generator.js` (the MIT `qrcode-generator` by Kazuhiko Arase, single file), referenced from `index.html`.

- [ ] **Step 1:** Add the library file and a `<script src="vendor/qrcode-generator.js"></script>` tag in `index.html`'s head. (Single dependency, no build step. If inlining is preferred for the single-file ethos, paste it into a `<script>` block instead.)
- [ ] **Step 2: Verify.** Load `index.html`; in the console `typeof qrcode === 'function'`.
- [ ] **Step 3: Commit.** `git add vendor/qrcode-generator.js index.html && git commit -m "chore: vendor qrcode-generator (MIT) for the hand-off QR"`

### Task C2: "Continue on another phone" panel at Stage 2

**Files:** Modify `index.html` — the Stage-2 screen (~:1195 onward) + a small JS function.

- [ ] **Step 1:** Add a "Continue on another phone" button to the Stage-2 prep area. On click, render a panel with the QR of the resume URL and instructions:

```js
function nxShowHandoff() {
  const url = `${location.origin}${location.pathname}#s=${encodeURIComponent(NX.token)}`;
  const el = document.getElementById('handoffQr');
  const qr = qrcode(0, 'M'); qr.addData(url); qr.make();
  el.innerHTML = qr.createSvgTag({ cellSize: 5, margin: 2 });
  document.getElementById('handoffPanel').style.display = 'block';
  nxStartHandoffPoll();
}
```

(Show the QR + "Scan with your second phone's camera, then photograph this device front and back." Keep the existing same-device "Take Photos Now" path intact.)

- [ ] **Step 2: Verify.** Manually open Stage 2 in a browser (preview/real token), click the button, confirm a scannable QR renders and encodes `#s=<token>`.
- [ ] **Step 3: Commit.** `git commit -am "feat(ui): Stage-2 'continue on another phone' QR hand-off panel"`

### Task C3: Phone-1 result hand-back (poll `session_get`)

**Files:** Modify `index.html` — add `nxStartHandoffPoll`.

- [ ] **Step 1:** While the hand-off panel is open, poll every 3s:

```js
let nxHandoffTimer = null;
function nxStartHandoffPoll() {
  if (nxHandoffTimer) return;
  nxHandoffTimer = setInterval(async () => {
    const d = await nxCall('session_get', { p_token: NX.token });
    if (d && d.data && d.data.session) {
      const s = d.data.session.status;
      if (s === 'complete' || s === 'failed' || s === 'expired') {
        clearInterval(nxHandoffTimer); nxHandoffTimer = null;
        NX.session = d.data.session;
        nxRouteByStatus();   // reuse the existing DOMContentLoaded status router (extract if inline)
      }
    }
  }, 3000);
}
```

- [ ] **Step 2:** Extract the existing status-routing block (`index.html:2807-2825`) into a named `nxRouteByStatus()` so both load and the poll can call it (DRY).
- [ ] **Step 3: Verify.** `deno`/browser console: open the panel, complete the session from a second tab on the same token, confirm phone-1 routes to the result screen.
- [ ] **Step 4: Commit.** `git commit -am "feat(ui): phone-1 polls for the hand-off verdict and shows the result"`

---

## Deploy & end-to-end verification (after all tasks)

- [ ] **Diff the live edge fn** against this repo's `edge-function-upload-and-process.ts` before deploying (drift risk). 
- [ ] **Apply** `schema-fix-13.sql` then `schema-fix-14.sql` to the live MVP Supabase; **redeploy** the edge function (A+B must deploy together — the RPC signature changed).
- [ ] **Push** `aia-qr-demo` to `origin` (write access now available).
- [ ] **Manual two-phone test over HTTPS** (tunnel/deploy): phone-1 reaches Stage 2 → "Continue on another phone" → phone-2 scans → uploads front+back → phone-1 shows the result. Hammer uploads from both phones on one network to confirm no 429.

## Out of scope
Fraud-binding (rolling code/sweep/model cross-check), server-authoritative eligibility, production rate-limit hardening, migrating to the prod rebuild.
