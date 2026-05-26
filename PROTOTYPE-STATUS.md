# Nexacore Device Check — Status & Handoff

## What This Product Is

A web-based device condition assessment tool for used-phone protection plans. Partners (insurers, MVNOs, telcos) send a link to their customer. The customer opens it on their phone, completes a 2-stage check, and the results flow back to the partner's sales process. No app download required.

**Target users:** Insurance agents selling device protection as an add-on. The check is sent to the end customer (device owner) via WhatsApp, SMS, email, or embedded in the partner's app via WebView.

**Current state:** pilot-ready MVP. Customer flow + admin dashboard + edge functions are live in production. See `COMMERCIAL-READINESS.md` for the gap-to-commercial-grade roadmap.

## Repo Layout

| File / folder | Purpose |
|---|---|
| `index.html` | **Customer-facing app** — single-file HTML/CSS/JS, deployed to GitHub Pages |
| `admin.html` | **Partner dashboard** — token-gated, lists sessions, drill-in to detail |
| `admin-config.js` | Local admin token (gitignored, never committed) |
| `edge-function-upload-and-process.ts` | `smart-handler` — upload + IMEI OCR + Gemini photo analysis + rejection rules |
| `edge-function-admin-detail.ts` | `admin-detail` — fetches one session with signed photo URLs |
| `schema.sql` | DB schema baseline (Phase 1 tables) |
| `schema-fix-01.sql` … `schema-fix-11.sql` | Migrations layered on top of `schema.sql`, apply in order |
| `nexacore-brand.md` | Brand colours and typography |
| `.env` | Supabase URL + service role key (gitignored) |
| `gcp-vision-key.json` | Google Cloud service account (gitignored) |
| `CLEANUP-AUDIT.md` | Cleanup punch list for engineer handoff |
| `COMMERCIAL-READINESS.md` | Phase A/B/C roadmap to commercial-grade |
| `RUNBOOK.md` | How to run/deploy locally (engineer onboarding) |

## Architecture

```
Customer phone (index.html on GH Pages)
        │
        ├─ session_get / session_complete_stage1/2  ──►  Supabase Postgres (RLS-protected RPCs)
        │
        └─ smart-handler edge function ──►  Supabase Storage + Vision OCR + Vertex Gemini

Admin (admin.html on GH Pages)
        │
        ├─ admin_list_sessions RPC                  ──►  Supabase Postgres
        └─ admin-detail edge function               ──►  Postgres + signed Storage URLs (15-min expiry)
```

- **Hosting:** GitHub Pages for the two HTML files. Branch `main`, root path.
- **Backend:** Supabase (Singapore region) — Postgres + Storage + Edge Functions (Deno).
- **Vision:** Google Cloud Vision API (OCR for IMEI) + Vertex AI Gemini 2.5 Flash (photo damage analysis).
- **Customer URL:** `https://nexacore-my.github.io/device-check/#s=<session_token>`
- **Admin URL:** `https://nexacore-my.github.io/device-check/admin.html`

## Screen Flow (Customer, 8 screens)

1. **Welcome** — "As easy as 1, 2, 3" intro. Start button.
2. **Before You Begin (prep)** — tappable checklist (volume, permissions, remove case, fully open fold phones, mirror nearby). Taps also help cover touch zones and create the AudioContext for the speaker test.
3. **Automated Scan** — runs the 7 diagnostic checks below.
4. **Capture IMEI** — instructions to dial `*#06#`, take screenshot, upload. Vision OCR + Luhn validation runs on submit; hard fail if no 15-digit number found.
5. **Stage 1 Results** — pass/fail per diagnostic.
6. **Stage 2 Verify** — explains the photo step.
7. **Condition Photos** — front screen photo + back photo via mirror. Gemini photo analysis runs on each upload — pre-existing damage hard-fails the session permanently. Other rejections (case visible, fold closed, obscured, photo unusable) allow retry up to 3 attempts.
8. **Final Results** — overall pass/fail.

## Diagnostic Checks (Screen 2)

| Check | What it does | Pass criteria | Notes |
|---|---|---|---|
| **Device Identity** | Parses UA, generates hardware fingerprint hash | UA parsed | Fingerprint hashes screen res, CPU cores, RAM, GPU, pixel ratio. **Not unique per device** — same model = same hash. Cannot replace IMEI. UA detection regressing on modern Chrome/Android (task #47). |
| **Cameras** | Opens front + rear, captures a frame, brightness + variance check | brightness > 5 AND variance > 50 on both | Catches dead/blocked cameras only. Lens-glass damage detected via Stage 2 mirror photos. |
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
- Customer flow (8 screens, all 7 diagnostics, IMEI OCR, photo analysis, retry UX)
- Smart-handler edge function (Vision OCR + Vertex Gemini + rejection rules + storage + rate limits + audit log)
- Admin-detail edge function (signed-URL fetching with 15-min expiry)
- Admin dashboard (`admin.html`) with token gate, session list, filter/search/sort, click-through detail, webhook preview
- Postgres schema (sessions, photos, diagnostics, webhook_deliveries, audit_log, partners)
- Security: RLS lockdown, rate limits (per IP + per session), session token in URL fragment, terminal-fail on pre-existing damage, admin signed URLs short-lived
- Audit log records IP + user_agent on every event
- Damage rejection rules tightened across iPhone 17 Pro, fold phones, mirror-flipped damage descriptions

**Not yet built:**
- **Internationalisation** (task #67) — schema is ready (`'en' | 'ms'`), backend returns language to client, but all UI strings are hardcoded English and LLM `user_message` returns are English-only. Day-one MVP requirement per project brief.
- **Partner provisioning UI** — adding a new partner is currently a SQL insert.
- **Webhook delivery** — `webhook_deliveries` table exists, `webhook_url` and `webhook_secret` are on partners, but the actual outbound POST + retry loop is not implemented.
- **Server-side PDF reports** — client-side PDF was removed; server-rendered report is on the roadmap.
- **GSMA / IMEI database integration** (task #57) — currently we Luhn-check the IMEI but do not look up make/model or blacklist status.
- **Engineer-facing structure work** — see `CLEANUP-AUDIT.md` (split monoliths, extract `_shared/`, unit tests, etc.).

## Known Limitations

- **Display test** — fast users only hit 4/9 zones (threshold is 5/9). May need a fallback interactive test.
- **Camera test** — dead cameras only. Physical lens damage relies on Stage 2 photos.
- **Sensor test** — intermittent failures on iOS if browser was backgrounded.
- **Storage check** — always passes (informational only).
- **Device identification** — Android brand/model regex regressing on modern Chrome (see UA Reduction above).
