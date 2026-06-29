# AIA Demo: Reliability/Rate-limit Fix + QR Second-Phone Hand-off — Design Spec

> Date: 2026-06-29 · Branch: `aia-qr-demo` (off `main`, **do not touch `main`** — it's the live demo) · Status: **for review**
> Repo: `Nexacore-MY/device-check` (the live MVP demo). Goal: make the demo AIA-ready.

## Goal & context
Get the live MVP demo ready to show **AIA** with the **second-phone QR hand-off**, reliably:
1. **Part A** — fix the "API error / rate-limit" bug (Gemini/Vision timeouts eating the per-session upload quota until the link locks). This is a **port of the proven fix already in `Device-check-prod`** (commits `0763506` + `626772b`).
2. **Part B** — relax the **per-IP** rate limit so a two-phone demo behind a tunnel/shared office IP doesn't trip `429`s. (New — not in prod.)
3. **Part C** — add the **QR second-phone hand-off** (happy-path UX), ported from the prod rebuild into the vanilla MVP.

Constraint: all work on `aia-qr-demo`. Backend changes (A, B) deploy to the **live MVP Supabase**; frontend changes (B3, C) ship with `index.html`.

---

## Part A — Reliability & quota fix (port from prod)
**Problem.** `edge-function-upload-and-process.ts` aborts Vision at 7s ([:460](../../../edge-function-upload-and-process.ts)) and Gemini at 12s ([:508](../../../edge-function-upload-and-process.ts)); Gemini's real slow tail is 13–14s, so ~50% of calls abort on a slow run. Every aborted call still increments the per-session upload quota (`session_check_upload_quota`, 10 photo / 5 imei), so a customer on a slow backend **burns the quota on infra failures and the link locks** mid-session with `429 "Upload quota exceeded for this session"`.

**Changes.**
- **A1 — raise timeouts:** Vision `7000 → 10000ms`, Gemini `12000 → 22000ms`.
- **A2 — new RPC `session_refund_upload_quota(p_token, p_kind)`** (new `schema-fix-13.sql`): decrements the consumed slot, `greatest(count - 1, 0)`. **Service-role only** — `revoke all from public, anon, authenticated; grant execute to service_role` (so a customer can't reset their own counter via the anon key). Direct port of `Device-check-prod/supabase/migrations/20260616000000_refund_upload_quota.sql`.
- **A3 — refund on infra failure:** in the edge function, when an upload fails for an **infra** reason (Vision/Gemini timeout or outage), call `session_refund_upload_quota` so the slot isn't burned. Distinguish `ocr_unavailable` (infra → refund) from `imei_not_readable` (genuine → counts), mirroring prod's `reliability.ts classifyImeiOutcome`. Keep it inline (the MVP edge fn is a single file).

**Verification.** Mirrors prod's parity-tested logic. Manual: force a slow/aborted analysis and confirm the quota slot is refunded and the session does not lock.

---

## Part B — Per-IP rate-limit relaxation (demo-safe; new)
**Problem.** `rl_check_and_increment` ([schema-fix-09.sql:91](../../../schema-fix-09.sql)) caps per IP per minute: **30/min** if the IP is visible, **10/min** if not — and when the IP is unknown it buckets **all** traffic under one global `"0.0.0.0"` key ([edge fn :427-431](../../../edge-function-upload-and-process.ts)). Behind a tunnel/proxy (IP stripped) the **entire demo shares one 10/min counter**; on a shared office Wi-Fi, all testers share 30/min. The QR hand-off puts **two phones per session** on the same network → doubles the load → `429 "Rate limit exceeded"` on stage.

**Design (chosen).**
- **B1 — kill the global unknown-IP collision:** when the IP is unknown, key the limiter by **session token** (`sess:<token>`) instead of `"0.0.0.0"`, so each session gets its own bucket. Generalise `rl_check_and_increment(p_ip inet, …)` → `rl_check_and_increment(p_key text, …)` (alter `rate_limits.ip inet` → `key text`), new `schema-fix-14.sql`. Edge fn passes the IP string when present, else `sess:<token>`.
- **B2 — demo-tuned caps:** known-IP `30 → 60/min`; per-session(unknown) `10 → 30/min`. **Explicitly demo-tuned** — revisit for production (the real production answer is server-authoritative eligibility + a proper per-session rate design, out of scope here). Safe because the per-session upload quota (10 photo / 5 imei) still bounds total uploads regardless.
- **B3 — frontend 429 copy:** a transient rate-limit `429` currently throws `"Upload failed: Rate limit exceeded"` ([index.html:1587](../../../index.html)) and elsewhere says *"start a new session"* — misleading (a new session on the same IP/tunnel re-trips it). Change rate-limit handling to a soft *"we're busy, retrying…"* with a short backoff+auto-retry, kept distinct from the per-session-quota terminal case.

---

## Part C — QR second-phone hand-off (happy-path UX)
**Mechanic (verified against MVP code).** Token rides `#s=<token>` ([index.html:1381-1386](../../../index.html)); `session_get` RPC exists ([:1407](../../../index.html)); the MVP already resumes a `stage1_complete` session at the photo step (its 72h "complete later" path). So a second phone opening the same link resumes at Stage 2 with no hand-back — identical to the prod implementation we already built and ran.

**Changes.**
- **C1 — vanilla QR generator:** add a small dependency-free QR generator inlined into `index.html` (the MVP is a single static file, no build step).
- **C2 — Stage-2 UI:** a "Continue on another phone" affordance → renders a QR of `${origin}/#s=${token}` + instructions + a waiting state. The existing same-device mirror flow is untouched.
- **C3 — phone-1 result hand-back:** while waiting, poll `session_get` every ~3s; when status is terminal (`complete`/`failed`), route to the existing result screen. (New poll; the RPC already exists.)
- **C4 — phone-2:** opens the link → existing resume to Stage 2 → existing upload → existing completion. **No new backend.**

**Scope.** Happy-path demo UX only. **No fraud-binding** (rolling code / continuous sweep / model cross-check) — that is the production phase, the same line drawn in the prod design. The demo is the *option/UX*, **not** "fraud-secure" — frame to AIA accordingly.

**Verification.** Manual two-phone test over **HTTPS** (cloudflared tunnel or deploy): phone-1 QR → phone-2 scans → uploads → phone-1 shows the result.

---

## Deploy / landing
- **Repo:** commit on `aia-qr-demo`; push to `origin` (write access now available). Never touch `main`.
- **Backend (A, B1/B2):** apply `schema-fix-13.sql` + `schema-fix-14.sql` and redeploy the edge function to the **live MVP Supabase** (access available). **Confirm the live edge function matches this repo before deploying** (drift risk).
- **Frontend (B3, C):** ships with `index.html` (static).
- **Sequencing:** A + B first (makes *any* demo reliable, including today's), then C. C without A/B will throw 429s.

## Out of scope / non-goals
- Fraud-binding for the QR hand-off (production phase).
- Server-authoritative eligibility (the real keystone; prod item 3).
- Production-grade rate-limit hardening (Part B is demo-tuned).
- Migrating the demo onto the prod rebuild (separate track).

## Risks
- **Live backend:** A & B deploy to the backend that serves the live demo — test on the branch and verify before the AIA session; coordinate timing with Melanie.
- **No automated tests** in the MVP (vanilla prototype) → rely on manual on-device verification + the fact that A mirrors prod's parity-tested logic.
- **Edge-fn drift:** the deployed edge function may differ from this repo file — diff before deploying.
- **HTTPS required** for phone-2's camera (tunnel/deploy).
