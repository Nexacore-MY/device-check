# Nexacore Device Check — Prototype Status & Production Handoff

## What This Product Is

A web-based device condition assessment tool for used phone protection plans. Partners (insurers, MVNOs, telcos) send a link to their customer. The customer opens it on their phone, completes a 2-stage check, and the results flow back to the partner's sales process. No app download required.

**Target users:** Insurance agents selling device protection as an add-on. The check is sent to the end customer (device owner) via WhatsApp, SMS, email, or embedded in the partner's app via WebView.

## Current Prototype File

- **Working version:** `device-check-v4.html`
- **GitHub Pages deployment copy:** `index.html` (synced with v4)
- **Brand guidelines:** `nexacore-brand.md`

## Screen Flow (8 screens, indexed 0-7)

1. **Screen 0 — Welcome:** "As easy as 1, 2, 3" intro. Start button.
2. **Screen 1 — Before You Begin (prep):** Tappable checklist — turn volume up, allow permissions, unmute phone, have mirror nearby. All must be checked to continue. This screen also serves a technical purpose: the taps help cover touch zones for the display test, and the "Continue" button tap creates the AudioContext needed for iOS speaker playback.
3. **Screen 2 — Automated Scan:** Runs 7 diagnostic checks automatically (see below). Shows checklist with live status updates.
4. **Screen 3 — Capture IMEI:** Instructions to dial *#06#, take screenshot, come back and upload. Also displays device fingerprint hash.
5. **Screen 4 — Stage 1 Results:** Shows pass/fail for each diagnostic. Continue to Stage 2.
6. **Screen 5 — Stage 2 Verify:** Explanation of what comes next (condition photos).
7. **Screen 6 — Condition Photos:** Front screen photo + back photo via mirror. Both required.
8. **Screen 7 — Final Results:** Overall pass/fail with all results. PDF report download.

## Automated Diagnostic Checks (Screen 2)

| Check | What It Does | Pass Criteria | Notes |
|-------|-------------|---------------|-------|
| **Device Identity** | Parses user agent to detect brand/model, generates hardware fingerprint hash | UA parsed successfully | Fingerprint = hash of screen res, CPU cores, RAM, GPU, pixel ratio, platform. NOT unique per device — same model phones produce same hash. Cannot replace IMEI. |
| **Cameras** | Opens front and rear cameras, captures a frame, analyses brightness and variance | Brightness > 5 AND variance > 50 for both cameras | Catches dead/blocked cameras only. Cannot detect cracked lens glass (tested — broken glass actually scored higher on sharpness). Physical damage detected via mirror photos in Stage 2. |
| **Sensors** | Listens for `devicemotion` events for 1.5 seconds | Both accelerometer and gyroscope return non-null values | iOS requires sensor permission from user gesture. Permission request MUST be first thing after tap (before AudioContext creation) or iOS considers the gesture stale and silently denies. |
| **Microphone** | Requests getUserMedia audio, checks track state | Audio track readyState === 'live' and enabled | Simplified to track-state check. Previous approaches (frequency analysis, time domain analysis) failed on Android due to AudioContext issues. Track-state is reliable cross-platform. |
| **Speaker** | Plays 880Hz sine tone for 0.5s using shared AudioContext | No errors thrown during playback | AudioContext MUST be created from a user gesture (the prep screen "Continue" tap). Stored in `sharedAudioCtx` global. iOS blocks AudioContext creation outside user gestures. |
| **Display** | Tracks touch zones via touchmove events across a 3x3 grid | 5 out of 9 zones touched | Passive tracking — no interactive grid. Touchmove during scrolling doesn't help (finger stays in same viewport position). Prep screen checkboxes help cover more zones. |
| **Storage & Memory** | Reads navigator.storage.estimate(), hardwareConcurrency, deviceMemory | Always passes (informational) | `navigator.deviceMemory` not available on iOS Safari — report shows "Not available (iOS)". |

## Pass/Fail Logic

- **Currently set to strict for demo:** ANY single check failure = overall FAIL
- **Production should be configurable per partner** — the code previously allowed 1 non-critical failure (sensors, mic, speaker, screen) as a CONDITIONAL PASS. Critical checks (identity, camera) always required pass.
- Stage 2 additionally requires: IMEI screenshot uploaded + both condition photos uploaded

## Key Technical Decisions & iOS/Android Gotchas

### iOS
- **AudioContext must be created from user tap.** Created on prep screen "Continue" button. Stored as `sharedAudioCtx`. Used by speaker test. If created too late or in a setTimeout, iOS suspends it.
- **Sensor permission must be requested immediately after tap.** Moved to first action in `requestPermissionsAndStart()` before AudioContext creation. If AudioContext creation runs first, the gesture window expires and sensor permission silently fails.
- **`navigator.deviceMemory` not supported.** RAM shows "Not available (iOS)" in report.

### Android
- **Mic AudioContext analyser unreliable.** Frequency data and time domain data both returned zeros on Android Chrome even with working mic. Switched to simple track-state check (getUserMedia succeeds + track is live = pass).
- **IMEI screenshot may be JPEG not PNG.** PDF embed now detects format from data URL prefix instead of hardcoding PNG.

### Both Platforms
- **Camera test cannot detect physical lens damage.** Broken/missing glass still produces images with valid brightness and variance. Sharpness analysis was tested and removed — broken glass scored HIGHER than intact glass due to more edge contrast from cracks. Mirror photos are the real physical damage check.
- **Touch zone tracking is passive.** No interactive game or grid. Relies on natural interaction (scrolling, tapping checkboxes on prep screen). 5/9 threshold is a pragmatic compromise — fast users may only get 4/9.

## What the PDF Report Contains

- Nexacore branded header with report ID and timestamp
- Overall PASS/FAIL badge (top right)
- Device info: brand, model, platform, screen resolution, CPU cores, RAM, fingerprint hash
- Diagnostic results table: each check with status and detail
- IMEI screenshot (embedded image, format auto-detected)
- Condition photos (screen + back, embedded)

## What Needs to Happen for MVP Production

### Backend (Supabase + Google Cloud Vision)
1. **Partner configuration layer** — API key, webhook URL, branding (logo/colours), language, pass/fail thresholds per partner
2. **Unique session links** — partner calls API to generate a check link tied to their client/policy reference
3. **OCR for IMEI** — Google Cloud Vision TEXT_DETECTION on uploaded IMEI photo. Auto-extract IMEI number, validate against device fingerprint. First 1000 requests/month free, $1.50/1000 after.
4. **Result webhook** — when check completes, POST structured payload (pass/fail, diagnostics, IMEI, photos, device profile) to partner's callback URL
5. **Photo storage** — secure storage of condition photos linked to policy record. Baseline for future claims comparison.
6. **Report storage** — server-generated reports instead of client-side PDF

### Internationalisation
- **All display text must use language keys, not hardcoded strings.** This is a day-one requirement. Partner specifies language code in check link. App loads correct language file.
- Start with English + Bahasa Malaysia.

### Partner Integration
- **No SDK needed.** Partners connect via: WebView (embed URL in their app), iFrame (web portals), or direct link (WhatsApp/SMS/email).
- **Quote system flexibility** — some partners quote before check, others check before quote. Our API is the same either way — partner decides sequencing.
- **Onboarding a new partner** = configuration only (logo, webhook URL, API key, language, thresholds). Target: under 1 hour per partner.

### Future Roadmap (Not MVP)
- **ML damage detection** — custom AutoML model trained on real damaged device images from Nexacore's existing claims administration work. Would enable automated crack/scratch/dent detection from condition photos.
- **Claims check** — second device check at claim time compared against enrolment baseline to identify new damage.
- **Full insurance admin platform** — quote engine, policy management, premium collection, claims handling. Phase 2/3. Device Check is the foundation product.

## Known Prototype Bugs / Limitations

1. **Display test** — fast users only get 4/9 zones. Threshold is 5/9. May need fallback interactive test for production.
2. **Camera test** — only catches dead cameras. Physical damage requires human review of photos (or future ML model).
3. **Sensor test** — intermittent failures on iOS if browser was backgrounded. Timeout is 1.5s — production could add retry logic.
4. **Report "Storage" section** — always shows passed. Informational only. iOS doesn't expose detailed storage/battery info.

## Files in This Project

| File | Purpose |
|------|---------|
| `device-check-v4.html` | Current working prototype (authoritative) |
| `index.html` | GitHub Pages deployment copy (keep synced with v4) |
| `device-check-v3.html` | Border trace version (abandoned) |
| `device-check-v2.html` | Prior v2 backup |
| `indexv2.html` | Prior v2 code backup from GitHub |
| `nexacore-brand.md` | Brand colours and typography |
| `Device Check - Demo Talking Points.docx` | Non-technical demo guide for insurer presentations |
| `PROTOTYPE-STATUS.md` | This file |
