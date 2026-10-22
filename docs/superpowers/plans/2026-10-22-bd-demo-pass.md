# BD Demo Pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One permanent QR code per BD person. Each scan plus tap starts a fresh demo session, so nobody has to mint a link per demo.

**Architecture:**
- **Start page.** A static page, `start/index.html`, reads a pass code from the URL fragment (`/start/#c=<code>`). On a tap it calls a new anon RPC, `demo_start_session(p_code)`.
- **The RPC.** Defined in `schema-fix-17.sql`. It:
  - looks the pass up by the sha256 of the code;
  - enforces the per-hour and per-day caps, counting that pass's sessions under a row lock;
  - inserts a short-lived session under a separate `nexacore-bd-demo` partner;
  - returns only the token.
- **Handover.** The page then runs `location.replace('/#s=' + token)` and the existing app takes over unchanged.
- **Hardening first.** Because demos get easier, the double-photo-upload bug is fixed first in `index.html`.

**Tech Stack:** vanilla HTML/JS (no build), Supabase Postgres (plpgsql RPC, PostgREST), Vercel static hosting.

**Source design:** `context-nexa/product/bd-demo-links.md` (Option 2 + Option 1 config).

**Out of scope for this plan:**
- automatic 7-day clean-up (needs Melanie's OK and the Storage API);
- Gemini 429 backoff in `smart-handler` (separate change);
- per-prospect branding.

---

## File map

| File | Change | Responsibility |
|---|---|---|
| `index.html` | modify | Per-slot in-flight lock and accepted-slot lock on condition photos; guard on stage-2 auto-finalise |
| `schema-fix-17.sql` | create | BD partner, `demo_links` table, `sessions.demo_link_id`, `demo_start_session` RPC, grants |
| `scripts/demo-pass-test.sql` | create | Assertion tests for fix-17; run against a throwaway DB, rolled back |
| `scripts/demo-pass-new.sql` | create | SQL-editor snippet that creates one pass and prints its QR URL once |
| `start/index.html` | create | The page the QR opens: one button, calls the RPC, hands over to the app |
| `.vercelignore` | modify | Exclude `scripts/` from the public deploy |
| `RUNBOOK.md` | modify | How to create, switch off and print a pass; BD admin view |

## Live steps — NOT part of the code tasks; each needs Levan's explicit OK

1. Push `aia-qr-demo` to origin. It is 12+ commits ahead, and the deployed demo exists only on the laptop.
2. Apply `schema-fix-17.sql` to the live MVP Supabase (`rysbsztwxjwndwebguuj`) through the SQL editor.
3. Create the first pass with `scripts/demo-pass-new.sql` and keep the printed URL.
4. Deploy with `vercel --prod` from `aia-qr-demo`.
5. Run end to end on real phones: scan the QR on an iPhone, finish the photos on an Android, then the reverse. Check the session shows under the BD partner.
6. BD admin view: an `admin-config.js` copy with `DEMO_PARTNER_SLUG: 'nexacore-bd-demo'` and the BD partner's `admin_token`. Only if Melanie wants BD to see results.

---

### Task 1: Stop duplicate condition-photo uploads

**Why:** PS-AIA7 (2026-08-04) re-uploaded an accepted screen photo three times, twice within a second. That made about 11 Gemini calls for 2 photos and used 10 of the 10 session slots. Nothing in `index.html` stops it:
- `handlePhoto` has no in-flight lock;
- accepted slots keep `onclick="capturePhoto(...)"`.

**Files:**
- Modify: `index.html` (NX state near line 1562, `capturePhoto` near 2548, `handlePhoto` near 2557, `submitStage2` near 2655)

- [ ] **Step 1: Write the failing check.** Paste this into the browser console on the app in preview mode (no `#s=`), where `nxUploadViaFunction` is stubbed:

```js
(async () => {
  let calls = 0;
  window.nxUploadViaFunction = async () => { calls++; await new Promise(r => setTimeout(r, 300)); return { success: true }; };
  window.nxDownscaleToBlob = async () => new Blob(['x'], { type: 'image/jpeg' });
  window.nxBlobToDataUrl = async () => 'data:image/jpeg;base64,eA==';
  const ev = () => ({ target: { files: [new File(['x'], 'a.jpg', { type: 'image/jpeg' })], value: 'a' } });
  currentPhotoSlot = 'screen';
  await Promise.all([handlePhoto(ev()), handlePhoto(ev())]);   // double fire while uploading
  currentPhotoSlot = 'screen';
  await handlePhoto(ev());                                      // re-upload after acceptance
  return calls;   // expected 1
})()
```

- [ ] **Step 2: Run it on the unmodified file.** Expected: `3`.

- [ ] **Step 3: Implement.** After `NX.MAX_ATTEMPTS = 3;` add:

```js
// One upload per photo slot at a time, and none once the slot is accepted. PS-AIA7 (2026-08-04)
// re-uploaded an accepted screen photo three times, twice within one second — every upload is a
// Gemini call and counts against the session's 10-slot cap, so it nearly locked a live demo.
NX.photoBusy = { screen: false, back: false };
NX.photoAccepted = { screen: false, back: false };
NX.stage2Submitting = false;
```

At the top of `capturePhoto(slot)`:

```js
  if (NX.photoBusy[slot]) { nxShowBanner('Still checking this photo — one moment…', 'info'); return; }
  if (NX.photoAccepted[slot]) { nxShowBanner(`${slot === 'screen' ? 'Screen' : 'Back'} photo already accepted ✓`, 'info'); return; }
```

In `handlePhoto`, right after `const slot = currentPhotoSlot;`:

```js
  if (NX.photoBusy[slot] || NX.photoAccepted[slot]) return;
  NX.photoBusy[slot] = true;
```

Give the outer `try` of `handlePhoto` a `finally { NX.photoBusy[slot] = false; }`. In the accepted branch, next to `badge.textContent = '✓';`, add `NX.photoAccepted[slot] = true;`.

At the top of `submitStage2`, after the photo-presence guard:

```js
  if (NX.stage2Submitting) return;   // both slots finishing together must not finalise twice
  NX.stage2Submitting = true;
```

In its `catch`, add `NX.stage2Submitting = false;` so a failed submit can be retried.

- [ ] **Step 4: Re-run the Step 1 check.** Expected: `1`. Also check that a soft rejection still allows a retake: stub the upload to return `{ rejected: true, reason: 'phone_case_on', user_message: 'x' }`, call `handlePhoto` twice in sequence, and expect 2 calls.

- [ ] **Step 5: Commit**

```bash
git add index.html
git commit -m "fix(photos): one upload per slot at a time; accepted photos are final"
```

### Task 2: Demo-pass schema and RPC (test first)

**Files:**
- Create: `scripts/demo-pass-test.sql`
- Create: `schema-fix-17.sql`

**Test database:** the local Supabase image, `public.ecr.aws/supabase/postgres:17.6.1.155`, with `schema.sql` and `schema-fix-01…16` replayed. Only the storage policies in 06–09 fail there, which is expected because there is no storage schema. **Never the live project.**

- [ ] **Step 1: Write the test.** Create `scripts/demo-pass-test.sql`; the full content is the committed file. It covers:
  - valid code → token, BD partner, `policy_ref demo-<label>-…`, 4h expiry, `demo_link_id` and the audit row;
  - a second tap gives a different token;
  - the hourly cap, then the daily cap after the clock moves;
  - wrong, short and null codes;
  - inactive pass, expired pass, inactive partner;
  - anon can call the RPC but cannot read `demo_links` or `sessions`;
  - `session_get` works on the new token;
  - the label check rejects `CHANGE-ME`.

- [ ] **Step 2: Run it before the migration.** Expected: fails with `relation "demo_links" does not exist`.

```bash
psql -h 127.0.0.1 -p 55432 -U postgres -v ON_ERROR_STOP=1 -f scripts/demo-pass-test.sql
```

- [ ] **Step 3: Write `schema-fix-17.sql`.** Full content is the committed file.

- [ ] **Step 4: Apply the migration twice (to prove it re-runs safely), then run the test.** Expected: `NOTICE:  demo-pass tests: ALL PASSED`.

- [ ] **Step 5: Commit**

```bash
git add schema-fix-17.sql scripts/demo-pass-test.sql
git commit -m "feat(demo): schema-fix-17 — BD demo passes mint a fresh capped session per tap"
```

### Task 3: Pass-creation snippet

**Files:**
- Create: `scripts/demo-pass-new.sql`

- [ ] **Step 1:** Write the snippet. It deliberately ships with label `CHANGE-ME`, which fails the label check, so it cannot run unedited.
- [ ] **Step 2:** On the test DB, run it unedited and expect a check-constraint error. Then edit the label to `bd-test`, run it, and expect one row with `https://demo.nexcheck.io/start/#c=<32 hex>`.
- [ ] **Step 3:** Call `demo_start_session('<that code>')` and expect a token.
- [ ] **Step 4: Commit**

```bash
git add scripts/demo-pass-new.sql
git commit -m "chore(demo): SQL-editor snippet to create a demo pass and print its QR URL"
```

### Task 4: Start page

**Files:**
- Create: `start/index.html`
- Modify: `.vercelignore` (add `scripts/`)

- [ ] **Step 1:** Write the page.
  - Read `c` from `location.hash`.
  - One button. On tap, disable it and `POST {SUPABASE_URL}/rest/v1/rpc/demo_start_session` with header `apikey: <publishable key>` only. The new keys are not JWTs, so they must not go in `Authorization: Bearer`.
  - On 200, `location.replace('/#s=' + token)`.
  - Map errors to plain messages:
    - `demo_link_invalid` → "not active";
    - `demo_limit_reached` → "today's limit";
    - network → "check connection", and re-enable the button.
  - No code in the fragment → "scan the QR from NexaCore".
- [ ] **Step 2:** Serve the repo root locally (`python3 -m http.server`). Then check:
  - `/start/` with no code shows the no-code message;
  - with `#c=<bogus>` and the live RPC absent (it isn't deployed yet), the error path shows a message and doesn't hang;
  - with `fetch` stubbed to return a token, the page navigates to `/#s=<token>`.
- [ ] **Step 3: Commit**

```bash
git add start/index.html .vercelignore
git commit -m "feat(demo): /start/ page — one tap turns a demo pass into a fresh session"
```

### Task 5: Runbook

- [ ] Add a "BD demo passes" section to `RUNBOOK.md` covering: create a pass, print its QR, switch it off, change caps, the BD admin view, and where the tests live. Commit.
