# Nexacore Device Check — Status & Handoff

## What This Product Is

A web-based device condition assessment tool for used-phone protection plans. Partners (insurers, MVNOs, telcos) send a link to their customer. The customer opens it on their phone, completes a 2-stage check, and the results flow back to the partner's sales process. No app download required.

**Target users:** Insurance agents selling device protection as an add-on. The check is sent to the end customer (device owner) via WhatsApp, SMS, email, or embedded in the partner's app via WebView.

**Current state:** pilot-ready MVP. Customer flow + admin dashboard + edge functions are live in production. See `CLEANUP-AUDIT.md` for the engineer-facing punch list.

## Repo Layout

| File / folder | Purpose |
|---|---|
| `index.html` | **Customer-facing app** — single-file HTML/CSS/JS (3,023 lines), deployed to Vercel |
| `admin.html` | **Partner dashboard** — token-gated, lists sessions, drill-in to detail (1,028 lines). Not published; run locally. |
| `admin-config.js` | Local admin token (gitignored, never committed) |
| `edge-function-upload-and-process.ts` | `smart-handler` — upload + IMEI OCR + TAC lookup + Gemini photo analysis + rejection rules (749 lines) |
| `edge-function-admin-detail.ts` | `admin-detail` — fetches one session with signed photo URLs (139 lines) |
| `schema.sql` | DB schema baseline (Phase 1 tables) |
| `schema-fix-01.sql` … `schema-fix-16.sql` | Migrations layered on top of `schema.sql`, apply in order (17 files with the baseline; no plain `08` — it is `08-diag`). `schema-fix-12.sql` adds the server-side photo-presence check that prevents `session_complete_stage2` from accepting a `pass` result unless both photos exist. `schema-fix-16.sql` creates `tac_catalogue` — **its 93k-row data load is out-of-band, see `RUNBOOK.md` §4.1**. |
| `nexacore-brand.md` | Brand colours and typography |
| `.env` | Supabase URL + service role key (gitignored) |
| `gcp-vision-key.json` | Google Cloud service account (gitignored) |
| `CLEANUP-AUDIT.md` | Cleanup punch list for engineer handoff |
| `RUNBOOK.md` | How to run/deploy locally (engineer onboarding) |

## Architecture

```
Customer phone (index.html on Vercel)
        │
        ├─ session_get / session_complete_stage1/2  ──►  Supabase Postgres (RLS-protected RPCs)
        │
        └─ smart-handler edge function ──►  Supabase Storage + Vision OCR + Vertex Gemini
                                            + tac_catalogue lookup (advisory make/model)

Admin (admin.html, run locally)
        │
        ├─ admin_list_sessions RPC                  ──►  Supabase Postgres
        └─ admin-detail edge function               ──►  Postgres + signed Storage URLs (15-min expiry)
```

- **Hosting:** **Vercel**, deployed with `vercel --prod` from branch **`aia-qr-demo`**. `admin.html` is excluded from the deploy (`.vercelignore`) and is run locally.
- **Backend:** Supabase (Singapore region) — Postgres + Storage + Edge Functions (Deno).
- **Vision:** Google Cloud Vision API (OCR for IMEI) + Vertex AI Gemini 2.5 Flash (photo damage analysis).
- **Customer URL:** `https://demo.nexcheck.io/#s=<session_token>`
- **Admin URL:** none — open `admin.html` from the repo.

⚠️ **GitHub Pages (`nexacore-my.github.io/device-check`, branch `main`) is the old pre-QR build** — mirror photo flow, no QR hand-off, no TAC. Not the live demo. See `RUNBOOK.md` §2.

## Screen Flow (Customer, 9 screens)

Screens are `#screen-0` … `#screen-8`, driven by `goToStep(n)`. Flow order below; note `screen-8` (the QR hand-off) was added last and so sits out of numeric order in the markup.

1. **Welcome** — "As easy as 1, 2, 3" intro. Start button.
2. **Before You Begin (prep)** — tappable checklist (volume, permissions, remove case, fully open fold phones). Taps also help cover touch zones and create the AudioContext for the speaker test.
3. **Automated Scan** — runs the 7 diagnostic checks below.
4. **Capture IMEI** — instructions to dial `*#06#`, take screenshot, upload. Vision OCR + Luhn validation runs on submit; hard fail if no 15-digit number found. On success the server also does a **TAC lookup** (first 8 IMEI digits → `tac_catalogue`) for the exact make/model — advisory only, never gates the result.
5. **Stage 1 Results** — pass/fail per diagnostic. Offers the hand-off to a second phone for the photo stage.
6. **Continue on another phone (QR hand-off)** — dedicated page (`screen-8`, added in `fe00f9e`) showing a QR to the same session with `&mode=capture`. The customer scans it with a second phone and photographs this device with that phone. This page polls `session_get` and swaps in the verdict when the photos land. Added as its own screen because inline on the Stage-1 summary it rendered below the fold.
7. **Stage 2 Verify** — explains the photo step.
8. **Condition Photos** — front screen photo + back photo, taken with the second phone. Gemini photo analysis runs on each upload — pre-existing damage hard-fails the session permanently. Other rejections (case visible, fold closed, obscured, photo unusable) allow retry up to 3 attempts.
9. **Final Results** — overall pass/fail.

## Diagnostic Checks (Screen 2)

| Check | What it does | Pass criteria | Notes |
|---|---|---|---|
| **Device Identity** | Parses UA, generates hardware fingerprint hash | UA parsed | Fingerprint hashes screen res, CPU cores, RAM, GPU, pixel ratio. **Not unique per device** — same model = same hash. Cannot replace IMEI. UA detection regressing on modern Chrome/Android (task #47). |
| **Cameras** | Opens front + rear, captures a frame, brightness + variance check | brightness > 5 AND variance > 50 on both | Catches dead/blocked cameras only. Lens-glass damage detected via the Stage 2 condition photos. |
| **Sensors** | Listens for `devicemotion` for 1.5s | Accelerometer + gyroscope non-null | iOS needs sensor permission from user gesture — requested first in `requestPermissionsAndStart()`. |
| **Microphone** | `getUserMedia` audio, checks track state | `track.readyState === 'live'` and enabled | Track-state only — frequency/time-domain analysis failed reliability on Android. |
| **Speaker** | Plays 880Hz sine 0.5s via shared `AudioContext` | No errors thrown | AudioContext created on the prep-screen "Continue" tap and reused. |
| **Display** | Touch zones via `touchmove` across 3x3 grid | ≥5 of 9 zones touched | Passive tracking. Prep checklist taps cover most zones. |
| **Storage & Memory** | `storage.estimate()` + `hardwareConcurrency` + `deviceMemory` | Always informational | `deviceMemory` unavailable on iOS — shown as "Not available (iOS)". |

## Pass/Fail Logic

- Critical checks (`identity`, `camera`) must pass.
- Non-critical (`sensors`, `mic`, `speaker`, `screen`) — currently 0 failures allowed for the demo. Production target is configurable per partner (1 non-critical failure = conditional pass).
- Stage 2 additionally requires: IMEI screenshot accepted + both condition photos accepted by Gemini.
- Any session with `pre_existing_damage` is marked `failed` permanently and cannot be retried.

## iOS / Android Gotchas (still relevant)

- **AudioContext must be created from a user tap.** Created on the prep-screen "Continue" button.
- **Sensor permission must be requested immediately after tap.** Before any `await` or `AudioContext` creation — otherwise iOS treats the gesture as stale and silently denies.
- **`navigator.deviceMemory` not supported on iOS.** Report shows "Not available (iOS)".
- **UA Reduction on Chrome/Android** strips brand and model from `navigator.userAgent`. `extractAndroidModel` and `identifyDevice` regex-match a string Chrome no longer emits — dashboard shows "Unknown Android Device" for most Android phones. Fix queued as #47 using `navigator.userAgentData.getHighEntropyValues`.
- **Fold phones (Samsung Galaxy Z Fold/Flip, Pixel Fold) ignore the `capture="user"/"environment"` hint** and may open the wrong camera. Customer flow now shows a manual flip-camera tip; longer-term plan is a `getUserMedia` + `enumerateDevices` custom UI (task #49).

## What's Built vs Not Built

**Built:**
- Customer flow (9 screens, all 7 diagnostics, IMEI OCR, QR hand-off to a second phone, photo analysis, retry UX)
- Smart-handler edge function (Vision OCR + TAC lookup + Vertex Gemini + rejection rules + storage + rate limits + audit log)
- Admin-detail edge function (signed-URL fetching with 15-min expiry)
- Admin dashboard (`admin.html`) with token gate, session list, filter/search/sort, click-through detail, webhook preview. Detail view carries a **"Model (from IMEI)"** row, and the detail title prefers the TAC label when it is high-confidence.
- Postgres schema (partners, sessions, diagnostics, photos, webhook_deliveries, audit_log, schema_migrations, rate_limits, rate_limits_text, tac_catalogue)
- **TAC make/model lookup** (shipped 2026-07-28, commit `eee8e08`) — the first 8 IMEI digits resolve against `tac_catalogue`, 93,042 model-bearing rows from `github.com/MoazEb/tac-database` (MIT, snapshot 2026-07-23). Replaces the screen-dimension guess, which could only ever offer a range ("iPhone 17 Pro Max / 16 Pro Max") because Apple strips the model from the user-agent.
  - **Advisory only. It is never an input to pass/fail** — it names the device on the record, nothing more.
  - The exact model **displays only at `high` confidence**, which needs all three of: the catalogue named a model, the IMEI's Luhn check passed, and the catalogue brand does not contradict the client's detected brand. Anything less shows the honest screen-size range. A wrong exact model on an enrolment record is worse than a range, because the insurer relies on it at claim time.
  - Runs **after** the IMEI is committed, under a 2s deadline, in try/catch, with a separate non-throwing update. A miss, DB error or hang can never fail the customer's upload — worst case `tac_confidence` stays `low`.
  - Stored as `sessions.tac_brand` / `tac_model` / `tac_confidence` / `tac_reason`, alongside (not overwriting) the client's own `device_brand` / `device_model` claim — a disagreement is itself evidence.
- Security:
  - RLS lockdown, rate limits (per IP + per session), session token in URL fragment
  - Terminal-fail on pre-existing damage
  - Admin signed URLs short-lived (15 min)
  - **Server-side photo presence check on stage 2 completion** — `session_complete_stage2` refuses `pass` unless both `screen` and `back` photos exist (schema-fix-12). Closes a bug where the frontend guard could be bypassed and the session marked pass with only one photo accepted.
  - **Smart-handler refuses uploads to terminal sessions** (status complete / failed / expired) — prevents stray rejection events on closed sessions.
- Audit log records IP + user_agent on every event
- Damage rejection rules tightened across iPhone 17 Pro, fold phones, mirror-flipped damage descriptions
- IMEI extractor handles iPhone 17 "Share Device Identifiers" screen (32-digit EID + 15-digit IMEI without false-matching inside the EID)

**Not yet built:**
- **Internationalisation** (task #67) — schema is ready (`'en' | 'ms'`), backend returns language to client, but all UI strings are hardcoded English and LLM `user_message` returns are English-only. Day-one MVP requirement per project brief.
- **Partner provisioning UI** — adding a new partner is currently a SQL insert.
- **Webhook delivery** — `webhook_deliveries` table exists, `webhook_url` and `webhook_secret` are on partners, but the actual outbound POST + retry loop is not implemented.
- **Server-side PDF reports** — client-side PDF was removed; server-rendered report is on the roadmap.
- **IMEI blacklist / stolen-device check** (the remaining half of task #57) — make/model now resolves via the TAC catalogue (see Built), but there is no lost/stolen or GSMA blacklist lookup.
- **Engineer-facing structure work** — see `CLEANUP-AUDIT.md` (split monoliths, extract `_shared/`, unit tests, etc.).

## Known Limitations

- **Display test** — fast users only hit 4/9 zones (threshold is 5/9). May need a fallback interactive test.
- **Camera test** — dead cameras only. Physical lens damage relies on Stage 2 photos.
- **Sensor test** — intermittent failures on iOS if browser was backgrounded.
- **Storage check** — always passes (informational only).
- **Device identification** — Android brand/model regex regressing on modern Chrome (see UA Reduction above).
- **The screen-size model guess can be WRONG, not merely vague.** Found in the 2026-07-28 TAC backtest: one device was offered as "iPhone 13 Mini / 12 Mini / X / XS" but is an **iPhone 11 Pro** — not in the range at all. The range reads like a safe hedge and isn't one. This is the fallback whenever the TAC lookup misses or lands `low`, so it is still on screen today.
- **`extractImei` accepts ICCIDs as IMEIs.** SIM card serials start `89`, run 15+ digits, and are **also Luhn-validated**, so the extractor takes one as a valid IMEI. Three of the ~97 IMEIs in the 2026-07-28 backtest were ICCIDs — the customer had screenshotted the wrong number and nothing objected. Fix would be to reject `89` prefixes, or to require a TAC catalogue hit before accepting.
- **A TAC miss degrades silently.** No catalogue row, an empty `tac_catalogue` (see `RUNBOOK.md` §4.1), a DB error or a 2s timeout all end the same way: `tac_confidence` stays `low`, the flow falls back to the screen-size range, and no error surfaces to the customer or the operator. That is deliberate — the lookup must never cost someone their upload — but it means a broken catalogue looks exactly like a normal miss. `sessions.tac_reason` is where you tell them apart (`tac_not_found` / `brand_only` / `imei_checksum_failed` / `brand_conflict` / `lookup_error`).
- **Backtest result (2026-07-28, ~97 historical IMEIs):** 10 misses, of which only **one** was a genuine catalogue gap. The other 9 were test IMEIs or OCR capturing the wrong number entirely, including the three ICCIDs above.
- **LLM damage detection is non-deterministic.** Observed in production (session `2a393ee5`): the same cracked screen was scored "no visible damage, condition 9" on the first attempt and correctly flagged with multiple cracks on a later attempt. Customers who stop after a false-negative would slip through with undetected damage. The case-on rule currently only fires on back photos — front-glass crack detection is harder when a case is visible. Mitigation candidates: also reject screen photos when a case is visible; tighten the prompt's hairline-crack threshold; add a second-opinion model pass for borderline scores.
- **Stage 2 frontend submit-guard bypass** — observed once in production (session `1623df34`) — submit fired with only one photo accepted. Root cause on the frontend not yet identified; possible mobile-Safari quirk with the disabled attribute or a race. Backend now blocks this via schema-fix-12 regardless of frontend state.
