# Photo-Consistency Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the same physical phone produce the same enrolment result by fixing the three bugs that caused Melanie's "3 different results on one phone."

**Architecture:** Three independent fixes in the MVP demo (`Nexacore-MY/device-check`, branch `aia-qr-demo`): (1) the AI's case detection is enforced on both photos; (2) the photo-analysis prompt + validity gate adapt to direct (second-phone) photos vs mirror selfies via a `capture_mode` flag; (3) the second phone auto-finalises Stage 2 with a server-validated `pass` instead of stranding. Optional Task 4 makes the Stage-2 verdict server-authoritative.

**Tech Stack:** Vanilla JS (`index.html`), Deno edge function (`edge-function-upload-and-process.ts`), Supabase Postgres RPC (`schema-fix-NN.sql`). No test framework in this repo — verification is **simulation scripts run against real stored analysis** (Node) + on-device testing.

**Evidence base (the three runs of Melanie's clean phone):**
- A: case off, mirror selfie → score 10, **PASS** (correct)
- B: case **ON**, mirror selfie → score 5, "3 cracks" → **FAIL** (Task 1 bug)
- C: case off, **direct** 2nd-phone photo → score 10 clean, but `not_phone_in_mirror` → **stranded** (Task 2 + Task 3 bug)

**Deploy note:** `index.html` ships via `vercel --prod` (working-tree upload). `edge-function-upload-and-process.ts` and any `schema-fix-NN.sql` deploy via the **Supabase dashboard** → these touch the **shared backend** (the live MVP demo uses it too) — all three changes are strict improvements. Levan owns the deploy.

---

### Task 1: Enforce case detection on the screen photo (edge function) — ALREADY APPLIED

**Files:**
- Modify: `edge-function-upload-and-process.ts` (the `phone_case_visible` check in `evaluatePhotoAnalysis`, ~line 341) — **already changed in the working tree**

- [ ] **Step 1: Confirm the change is present**

Run: `grep -n "if (analysis.phone_case_visible)" edge-function-upload-and-process.ts`
Expected: one match (the back-only `photoKind === "back" &&` guard removed), so the case-removal prompt now runs on screen + back.

- [ ] **Step 2: Verify it flips the real failed session (simulation, no redeploy)**

Run this Node script (`/tmp/verify_task1.mjs` — reads the live stored analysis for session `ccd8f5…`, runs both rule versions):

```js
// /tmp/verify_task1.mjs — proves OLD(back-only)=pre_existing_damage, NEW(both)=phone_case_on
const SB='https://rysbsztwxjwndwebguuj.supabase.co';
const ANON='sb_publishable_Ca2iyY__GqNRUw2tYweqXg_Qz6DAzpi';
const ADMIN=process.env.NX_ADMIN_TOKEN;          // export from admin-config.js, do not hardcode
const TOK='ccd8f50d756effcb6bf0fedf620d71b637fb';
const r=await fetch(`${SB}/functions/v1/admin-detail`,{method:'POST',
  headers:{apikey:ANON,Authorization:`Bearer ${ANON}`,'Content-Type':'application/json'},
  body:JSON.stringify({admin_token:ADMIN,session_token:TOK})});
const d=await r.json();
const an=d.audit_log.find(e=>e.event_data?.analysis&&e.event_data.slot==='screen').event_data.analysis;
function ev(a,kind,caseBoth){
  if(!a.is_phone_in_mirror)return'not_phone_in_mirror';
  if(a.photo_quality==='unusable')return'photo_unusable';
  if(a.device_visibility==='obscured')return'device_obscured';
  if((caseBoth||kind==='back')&&a.phone_case_visible)return'phone_case_on';
  for(const x of (a.damage||[])){
    const crit=['screen_crack','back_glass_crack','structural_damage'].includes(x.type);
    if(crit&&x.confidence!=='low')return'pre_existing_damage';
    if(x.confidence==='high'&&x.severity!=='minor')return'pre_existing_damage';
  }
  return'ACCEPTED';
}
console.log('OLD(back-only):',ev(an,'screen',false));
console.log('NEW(both)    :',ev(an,'screen',true));
```

Run: `NX_ADMIN_TOKEN=$(grep -oE "ADMIN_TOKEN['\"]?[ ]*:[ ]*['\"][^'\"]+" admin-config.js | sed -E "s/.*['\"]([^'\"]+)$/\1/") node /tmp/verify_task1.mjs`
Expected:
```
OLD(back-only): pre_existing_damage
NEW(both)    : phone_case_on
```

- [ ] **Step 3: Commit (deferred — commit all edge-fn changes together at end of Task 2)**

---

### Task 2: Adapt the prompt + validity gate for direct (second-phone) photos

The second-phone flow sends a **direct** photo, but the prompt hard-codes "mirror" (left/right reversed) and `evaluatePhotoAnalysis` rejects unless `is_phone_in_mirror`. The phone-1 "Take Photos Now" flow is still a real mirror selfie, so we **branch on a `capture_mode` flag** instead of removing mirror logic.

**Files:**
- Modify: `index.html` — `nxUploadViaFunction` (add the `capture_mode` form field, ~line 1611)
- Modify: `edge-function-upload-and-process.ts` — read `capture_mode`; thread it through `analyzePhoto`/`analyzePhotoGemini`/`PHOTO_ANALYSIS_PROMPT`; branch `evaluatePhotoAnalysis`

- [ ] **Step 1: Client sends the capture-mode flag**

In `index.html` `nxUploadViaFunction`, after the three existing `formData.append(...)` lines, add:

```js
  formData.append('file', blob, `${kind}.jpg`);
  formData.append('capture_mode', NX.captureMode ? '1' : '0');   // NEW: direct (2nd-phone) vs mirror
```

- [ ] **Step 2: Edge fn — read the flag**

In `edge-function-upload-and-process.ts`, in the handler where `kind`/`file` are read (~line 391), add:

```js
    const kind = String(form.get("kind") ?? "");
    const file = form.get("file") as File | null;
    const captureMode = String(form.get("capture_mode") ?? "") === "1";  // NEW
```

- [ ] **Step 3: Edge fn — make the prompt direct-aware**

Replace `PHOTO_ANALYSIS_PROMPT = (photoKind: "screen" | "back") => \`...\`` (~line 214) so it takes `isDirect` and swaps two passages. The signature becomes `PHOTO_ANALYSIS_PROMPT(photoKind, isDirect)`. Change the opening lines and the location-guidance bullet:

```ts
const PHOTO_ANALYSIS_PROMPT = (photoKind: "screen" | "back", isDirect: boolean) => {
  const framing = isDirect
    ? `You are analyzing a photo submitted for a mobile phone insurance enrolment (Accidental Damage Protection). A second person photographed the customer's phone DIRECTLY with another camera — this is NOT a mirror reflection.

Photo type: ${photoKind === "screen" ? "screen-side (front of the device)" : "back-side (back of the device)"}`
    : `You are analyzing a photo submitted for a mobile phone insurance enrolment (Accidental Damage Protection). The customer was asked to photograph their phone in a mirror.

Photo type: ${photoKind === "screen" ? "screen-side (front of device facing mirror)" : "back-side (back of device facing mirror)"}`;

  const locationGuidance = isDirect
    ? `- DIRECT PHOTO: This is a direct photo (NOT a mirror), so left and right are NOT reversed. Report each damage "location" exactly as you see it, from the user's perspective holding the device normally. Top and bottom are unchanged.`
    : `- MIRROR IMAGE: This photo is a mirror reflection, so left and right are REVERSED. When reporting "location" in damage entries, describe the location from the user's perspective holding the device normally (NOT from how it appears in the photo). If damage appears on the RIGHT side of the device in the image, report it as the "LEFT" side (because the mirror has flipped it). Top and bottom are unchanged. Use "top-left corner", "bottom-right edge", etc., referring to the device's actual orientation, not the mirrored view.`;

  return `${framing}

Analyze this image and respond with ONLY valid JSON in this exact structure (no markdown, no preamble, no commentary):

{
  "is_phone_in_mirror": boolean,
  "photo_quality": "good" | "poor" | "unusable",
  "photo_quality_reason": "brief explanation",
  "device_visibility": "full" | "partial" | "obscured",
  "phone_case_visible": boolean,
  "is_fold_phone_closed": boolean,
  "damage": [
    {
      "type": "screen_crack" | "back_glass_crack" | "structural_damage" | "scratch" | "dent",
      "severity": "minor" | "moderate" | "severe",
      "location": "brief description",
      "confidence": "low" | "medium" | "high"
    }
  ],
  "condition_score": 1-10,
  "summary": "1-2 sentence overall description"
}

Critical guidance:
${locationGuidance}
- This is for INSURANCE ENROLMENT. Missing pre-existing damage costs the insurer money. Prefer false-positive over false-negative for ANY damage detection.
- CRACKS: any visible line, fracture, or break in the glass surface — even a single hairline — must be reported as a crack (screen_crack or back_glass_crack), NOT as a scratch. If unsure between crack and scratch, classify as crack with medium confidence.
- A reflection on glass is NOT a crack. Cracks have actual line patterns through the glass surface, often originating from an impact point.
- The screen may be DISPLAYING a wallpaper, photo, or app — content WITHIN the displayed image (lines, edges, tree branches, text), and reflections/glare on the glass, are NOT cracks. A real crack is a fracture IN the glass with an impact origin, independent of what is on screen.
- SCRATCHES are surface marks that don't penetrate the glass — they show no spider pattern or impact origin.
- "phone_case_visible": Default to FALSE. Only set TRUE if you are highly confident a protective case is fitted. Specific things that are NOT a case (return FALSE for these):
  • A hand, fingers, or palm wrapping around the device — that's the user holding their phone, not a case.
  • The phone's own back panel finish — modern iPhones (15 Pro / 16 Pro / 17 Pro) have titanium frames and matte/textured glass backs that can look distinct from the screen side.
  • IMPORTANT — iPhone 17 Pro and 17 Pro Max back design: these models have a LARGE HORIZONTAL "camera plateau" spanning almost the FULL WIDTH of the upper back third, a DIFFERENT COLOUR / FINISH from the lower back by design. This two-tone back is native, NOT a case.
  • A clear screen protector on the front.
  Return TRUE only when you see ALL of: (a) a clear seam/border WRAPPING AROUND THE EDGES of the device where case material ends and device begins (a seam across only the back face is NOT enough — case seams wrap to the side rails), AND (b) case-specific features like raised port cutouts, button covers, or material that extends visibly over the device's corners and edges. When in real doubt, return FALSE.
- A clear screen protector on the FRONT is NOT a case. Only worry about cases on the back/edges.
- "is_fold_phone_closed": Default to FALSE. ONLY true when the device is clearly a fold/flip phone (Z Fold, Z Flip, Razr, Pixel Fold etc.) AND in the closed/folded state. An OPEN fold phone shows a SINGLE large continuous screen (a faint crease down the middle is NORMAL and means OPEN, not closed). If unsure, return FALSE.
- For ${photoKind === "back" ? "BACK photos: this is the critical one for case detection. Look for material covering the device back with a different colour, texture, or edge profile than the device body." : "SCREEN photos: examine the front glass carefully for ANY crack lines, even small ones — but ignore on-screen content, reflections, and glare per the rule above."}
- "condition_score": 10 = pristine, 7-9 = minor wear (scratches only), 4-6 = visible damage including any crack, 1-3 = heavily damaged.

Output only the JSON.`;
};
```

(This also folds in the wallpaper/reflection guidance that caused the palm-frond false read — a small, safe accuracy improvement applied to both modes.)

- [ ] **Step 4: Edge fn — thread `isDirect` through the call chain**

`analyzePhoto` (~line 304) and `analyzePhotoGemini` (~line 259) gain a final `isDirect: boolean` param; the prompt call becomes `PHOTO_ANALYSIS_PROMPT(photoKind, isDirect)`:

```ts
async function analyzePhotoGemini(imageBytes: Uint8Array, photoKind: "screen" | "back", signal: AbortSignal, isDirect: boolean): Promise<PhotoAnalysis> {
  // ...unchanged until the prompt...
          { text: PHOTO_ANALYSIS_PROMPT(photoKind, isDirect) },
  // ...
}
async function analyzePhoto(imageBytes: Uint8Array, photoKind: "screen" | "back", signal: AbortSignal, isDirect: boolean): Promise<PhotoAnalysis> {
  if (VISION_PROVIDER === "gemini") return analyzePhotoGemini(imageBytes, photoKind, signal, isDirect);
  throw new Error(`Provider ${VISION_PROVIDER} not implemented`);
}
```

And the call site in the handler (~line 521): `analysis = await analyzePhoto(fileBytes, kind as "screen" | "back", controller.signal, captureMode);`

- [ ] **Step 5: Edge fn — skip the mirror gate for direct photos**

`evaluatePhotoAnalysis` (~line 316) gains an `isDirect` param; only the first rule changes:

```ts
function evaluatePhotoAnalysis(analysis: PhotoAnalysis, photoKind: "screen" | "back", isDirect: boolean): { rejected: boolean; reason?: string; user_message?: string } {
  if (!isDirect && !analysis.is_phone_in_mirror) {
    return { rejected: true, reason: "not_phone_in_mirror", user_message: "We couldn't see your phone in a mirror. Please retake the photo with your phone facing a mirror." };
  }
  // ...rest unchanged (the Task-1 case check, fold check, damage check)...
}
```

Call site (~line 552): `const verdict = evaluatePhotoAnalysis(analysis, kind as "screen" | "back", captureMode);`

- [ ] **Step 6: Verify against the real stranded direct photo (simulation)**

Run (`/tmp/verify_task2.mjs`) against session at 06:29:27 (the `not_phone_in_mirror`, score-10 clean direct photo). Same shape as the Task-1 script, but the rule fn takes `isDirect` and gates `if(!isDirect && !a.is_phone_in_mirror) return 'not_phone_in_mirror'`. Find the stranded session token via `admin_list_sessions` (status `stage1_complete`, screen analysis `is_phone_in_mirror=false`).
Expected:
```
OLD (mirror gate):        not_phone_in_mirror   (clean phone rejected)
NEW (isDirect, gate off): ACCEPTED              (clean phone passes)
```

- [ ] **Step 7: Syntax-check the client**

Run: `node -e 'const fs=require("fs");const h=fs.readFileSync("index.html","utf8");const re=/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/gi;let m,b=0;while((m=re.exec(h))){try{new Function(m[1])}catch(e){b++;console.log(e.message)}}console.log("errors:",b)'`
Expected: `errors: 0`

- [ ] **Step 8: Commit the edge-fn + client mode changes (Tasks 1 + 2)**

```bash
git add index.html edge-function-upload-and-process.ts
git commit -m "fix(photos): enforce case-removal on both photos + direct-photo prompt/gate for 2nd-phone capture"
```

---

### Task 3: Second phone auto-finalises Stage 2 with a server-validated pass

Today the **pass** path is only finalised by a manual "Submit Photos" tap → `submitStage2()`, which computes the verdict from **phone-2's empty `report`** (no IMEI/diagnostics) and would compute *fail*. Fix: in capture mode, derive the verdict from "both photos accepted" (the edge fn already terminally-fails on damage; `session_complete_stage2`'s schema-fix-12 guard re-checks the photos) and **auto-submit** once both are accepted.

**Files:**
- Modify: `index.html` — `submitStage2` verdict branch (~line 2671); `handlePhoto` auto-finalise (~line 2631)

- [ ] **Step 1: Branch the verdict for capture mode in `submitStage2`**

Replace the `overallPass` line (~line 2671):

```js
    // Phone-2 (capture mode) holds no Stage-1 data — IMEI + diagnostics ran on phone-1.
    // The verdict is server-validated: session_complete_stage2 (schema-fix-12) only allows
    // 'pass' when BOTH photos are accepted, and the edge fn already fails terminally on damage.
    // So a capture session that reached here with both photos accepted = pass.
    const overallPass = NX.captureMode
      ? !!(report.photos.screen && report.photos.back)
      : (!criticalFail && nonCriticalFails === 0 && hasIMEI && photosOk);
```

- [ ] **Step 2: Auto-finalise once both photos are accepted (capture mode only)**

In `handlePhoto`, where the Submit button is enabled (~line 2631-2632), append the auto-finalise:

```js
    // Now check if both required photos are uploaded
    const hasRequired = report.photos.screen && report.photos.back;
    document.getElementById('btnPhotoSubmit').disabled = !hasRequired;
    // Second phone has no manual Submit step — auto-finalise so it doesn't strand at stage1_complete.
    if (NX.captureMode && hasRequired) submitStage2();
```

- [ ] **Step 3: Confirm `report.photos[slot]` is set on accept (read-only check)**

Run: `grep -n "report.photos\[slot\] =\|report.photos\[slot\]=\|delete report.photos\[slot\]" index.html`
Expected: an assignment on the accepted path and a `delete` on the rejected path. (If the assignment is missing, add `report.photos[slot] = { ...preview metadata };` in the accepted branch before the `hasRequired` check — the existing rejected branch already `delete`s it.)

- [ ] **Step 4: Syntax-check**

Run: the same Node syntax-check command from Task 2 Step 7.
Expected: `errors: 0`

- [ ] **Step 5: Commit**

```bash
git add index.html
git commit -m "fix(qr-handoff): 2nd phone auto-finalises Stage 2 (pass) once both photos accepted"
```

- [ ] **Step 6: On-device verification (Levan, after deploy)**

Deploy (`vercel --prod` for `index.html`; redeploy `smart-handler` for the edge fn). Run the full QR hand-off on a **clean, case-off** phone. Expect: 2nd phone shows "Assessment Complete"; phone-1's poll flips to the result; the admin shows `status=complete, overall_result=pass`, both photos `accepted`. Then probe the session via `admin-detail` to confirm `stage2_result=pass`.

---

### Task 4 (RECOMMENDED, separately deployable): Server-authoritative Stage-2 pass

Closes the "client decides eligibility" gap (item 3) so phone-2 can't claim a wrong `pass`. Strengthens `session_complete_stage2` to require, for a `pass`: both photos accepted (already present) **AND** `stage1_result='pass'` **AND** an extracted IMEI.

**Files:**
- Create: `schema-fix-15.sql`

- [ ] **Step 1: Write `schema-fix-15.sql`**

```sql
-- schema-fix-15.sql — make a Stage-2 'pass' server-authoritative.
-- Adds to the existing (schema-fix-12) photo guard: a 'pass' also requires the session to
-- have PASSED stage 1 and to hold an extracted IMEI. Prevents a second phone (which lacks
-- stage-1 data) or any client from claiming a pass the stored evidence doesn't support.
create or replace function session_complete_stage2(
  p_token text, p_result text, p_full_report jsonb
) returns void language plpgsql security definer set search_path = public as $$
declare
  v_session_id uuid; v_status text; v_expires timestamptz;
  v_stage1 text; v_imei text; v_accepted_slots int;
begin
  select id, status, expires_at, stage1_result, imei_extracted
    into v_session_id, v_status, v_expires, v_stage1, v_imei
    from sessions where token = p_token;
  if v_session_id is null then raise exception 'session not found' using errcode='42501'; end if;
  if v_expires < now() then raise exception 'session expired' using errcode='42501'; end if;
  if v_status in ('failed','expired','complete') then
    raise exception 'session is terminal (status=%)', v_status using errcode='42501'; end if;
  if p_result not in ('pass','fail') then raise exception 'invalid result' using errcode='22023'; end if;

  if p_result = 'pass' then
    select count(*) into v_accepted_slots from photos
      where session_id = v_session_id and slot in ('screen','back')
        and (status is null or status = 'accepted');
    if v_accepted_slots < 2 then
      raise exception 'cannot mark pass: only % of 2 required photos accepted', v_accepted_slots using errcode='42501'; end if;
    if v_stage1 is distinct from 'pass' then
      raise exception 'cannot mark pass: stage 1 did not pass (%)', coalesce(v_stage1,'null') using errcode='42501'; end if;
    if v_imei is null or length(v_imei) = 0 then
      raise exception 'cannot mark pass: no IMEI on record' using errcode='42501'; end if;
  end if;

  update sessions set
    status = 'complete', stage2_result = p_result, stage2_completed_at = now(),
    overall_result = p_result, full_report = p_full_report
  where id = v_session_id;
end; $$;

revoke all on function session_complete_stage2(text, text, jsonb) from public;
grant execute on function session_complete_stage2(text, text, jsonb) to anon;
```

- [ ] **Step 2: Deploy via Supabase SQL editor, then probe**

After running the SQL: re-run the full QR hand-off on a known-good phone → expect `pass`. Then run it on a phone where Stage 1 was skipped/failed → expect the RPC to reject the `pass` (session stays non-complete or errors), proving the server now decides.

- [ ] **Step 3: Commit the migration**

```bash
git add schema-fix-15.sql
git commit -m "feat(security): server-authoritative Stage-2 pass (stage1+imei+photos)"
```

---

## Self-Review

- **Spec coverage:** Result B (case) → Task 1. Result C reject (`not_phone_in_mirror`) → Task 2. Result C strand (no finalise) → Task 3. Verdict-from-empty-report → Task 3 Step 1 + Task 4. Wallpaper/glare false read → folded into Task 2 Step 3. ✓
- **Type consistency:** `isDirect`/`captureMode` is `boolean` throughout; `PHOTO_ANALYSIS_PROMPT(photoKind, isDirect)`, `analyzePhoto(..., isDirect)`, `evaluatePhotoAnalysis(analysis, photoKind, isDirect)` signatures match their call sites. Client flag name `capture_mode` matches `form.get("capture_mode")`. ✓
- **Placeholder scan:** none — every code step shows full code; verification scripts are runnable. ✓
- **Scope:** Tasks 1-3 = the demo-consistency fix (one redeploy of client + edge fn). Task 4 = optional security hardening (separate SQL deploy). ✓
