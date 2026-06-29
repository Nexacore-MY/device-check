// ============================================================
// Nexacore Device Check — Edge Function: smart-handler (upload + analysis)
// ============================================================
// Accepts multipart/form-data:
//   session_token: string
//   kind: "imei" | "screen" | "back"
//   file: image binary
//
// Per kind:
//   - imei: upload + Google Vision OCR; HARD FAIL if no 15-digit number found
//   - screen/back: upload + Gemini photo analysis; rejection rules applied
//     (not_phone_in_mirror, unusable, obscured, case_visible, fold_closed,
//      pre_existing_damage)
//
// On rejection: storage object is deleted, DB is NOT updated, error returned.
// Frontend handles retries (max 3 per slot).
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const GCP_CREDENTIALS = Deno.env.get("GCP_VISION_CREDENTIALS")!;

// LLM provider — swap by changing this constant. Implementations are below.
const VISION_PROVIDER: "gemini" | "claude" = "gemini";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, x-client-info, apikey",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });

// ============================================================
// Google OAuth2 — shared by Vision API and Gemini (Vertex AI)
// ============================================================
let cachedAccessToken: { token: string; expiresAt: number } | null = null;

async function getGcpAccessToken(): Promise<string> {
  if (cachedAccessToken && cachedAccessToken.expiresAt > Date.now() + 60_000) {
    return cachedAccessToken.token;
  }
  const creds = JSON.parse(GCP_CREDENTIALS);
  const now = Math.floor(Date.now() / 1000);
  const claim = {
    iss: creds.client_email,
    scope: "https://www.googleapis.com/auth/cloud-platform",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  };
  const b64url = (data: string) =>
    btoa(data).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
  const headerEnc = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claimEnc = b64url(JSON.stringify(claim));
  const message = `${headerEnc}.${claimEnc}`;
  const pemBody = creds.private_key
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s/g, "");
  const derBytes = Uint8Array.from(atob(pemBody), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    "pkcs8", derBytes,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false, ["sign"]
  );
  const sigBuffer = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5", key,
    new TextEncoder().encode(message)
  );
  const sigEnc = btoa(String.fromCharCode(...new Uint8Array(sigBuffer)))
    .replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
  const jwt = `${message}.${sigEnc}`;
  const tokenResp = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}`,
  });
  if (!tokenResp.ok) {
    throw new Error(`GCP token exchange failed: ${tokenResp.status} ${await tokenResp.text()}`);
  }
  const tokenData = await tokenResp.json();
  cachedAccessToken = {
    token: tokenData.access_token,
    expiresAt: Date.now() + (tokenData.expires_in || 3600) * 1000,
  };
  return cachedAccessToken.token;
}

// ============================================================
// Helper — base64 encode large image bytes without stack overflow
// ============================================================
function imageBytesToBase64(imageBytes: Uint8Array): string {
  let binary = "";
  const chunkSize = 32768;
  for (let i = 0; i < imageBytes.length; i += chunkSize) {
    binary += String.fromCharCode(...imageBytes.subarray(i, i + chunkSize));
  }
  return btoa(binary);
}

// ============================================================
// Google Vision API — IMEI OCR (TEXT_DETECTION)
// ============================================================
async function visionTextDetection(
  imageBytes: Uint8Array,
  signal: AbortSignal
): Promise<string> {
  const token = await getGcpAccessToken();
  const b64Image = imageBytesToBase64(imageBytes);
  const resp = await fetch("https://vision.googleapis.com/v1/images:annotate", {
    method: "POST",
    signal,
    headers: {
      "Authorization": `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      requests: [{
        image: { content: b64Image },
        features: [{ type: "TEXT_DETECTION", maxResults: 1 }],
      }],
    }),
  });
  if (!resp.ok) {
    throw new Error(`Vision API failed: ${resp.status} ${await resp.text()}`);
  }
  const data = await resp.json();
  return data.responses?.[0]?.fullTextAnnotation?.text ?? "";
}

function luhnCheck(digits: string): boolean {
  let sum = 0, alt = false;
  for (let i = digits.length - 1; i >= 0; i--) {
    let d = parseInt(digits[i], 10);
    if (alt) { d *= 2; if (d > 9) d -= 9; }
    sum += d;
    alt = !alt;
  }
  return sum % 10 === 0;
}

function extractImei(ocrText: string): { imei: string | null; valid: boolean } {
  // Split on non-digits so we can look at each whitespace-delimited digit group
  // independently. The IMEI on every device's *#06# screen (and Apple's "Share
  // Device Identifiers" screen) is exactly 15 digits flanked by whitespace.
  const digitGroups = ocrText.split(/\D+/).filter(Boolean);

  // STRATEGY A (preferred): exact-length-15 groups, Luhn-valid.
  // This is the canonical IMEI shape. Done first so we never confuse the IMEI
  // with a Luhn-valid 15-digit substring of a longer identifier (e.g. the 32-digit
  // EID on iPhone share screens contains Luhn-valid 15-digit substrings).
  for (const g of digitGroups) {
    if (g.length === 15 && luhnCheck(g)) return { imei: g, valid: true };
  }

  // STRATEGY B: 15 digits with single-char separators (some screens space groups out).
  const sepCandidates = ocrText.match(/(?:\d[\s.\-]?){15}/g) ?? [];
  for (const c of sepCandidates) {
    const digits = c.replace(/\D/g, "");
    if (digits.length === 15 && luhnCheck(digits)) return { imei: digits, valid: true };
  }

  // STRATEGY C: sliding 15-window inside slightly-longer runs (16-20 digits).
  // Catches the stitched-label bug (e.g. "IMEI1357..." → label "1" merged with
  // IMEI by OCR). Skip runs longer than 20 digits — those are clearly a
  // different identifier (EID is 32, UPC is 12-14) and matches inside them
  // are noise, not the IMEI.
  for (const g of digitGroups) {
    if (g.length <= 15 || g.length > 20) continue;
    for (let i = 0; i <= g.length - 15; i++) {
      const candidate = g.substring(i, i + 15);
      if (luhnCheck(candidate)) return { imei: candidate, valid: true };
    }
  }

  // Fallback (no Luhn-valid found anywhere). Prefer an exact-length-15 group.
  for (const g of digitGroups) {
    if (g.length === 15) return { imei: g, valid: false };
  }
  for (const c of sepCandidates) {
    const digits = c.replace(/\D/g, "");
    if (digits.length === 15) return { imei: digits, valid: false };
  }
  return { imei: null, valid: false };
}

// ============================================================
// Photo analysis — Gemini (default) or Claude
// ============================================================
type PhotoAnalysis = {
  is_phone_in_mirror: boolean;
  photo_quality: "good" | "poor" | "unusable";
  photo_quality_reason: string;
  device_visibility: "full" | "partial" | "obscured";
  phone_case_visible: boolean;
  is_fold_phone_closed: boolean;
  damage: Array<{
    type: string;
    severity: "minor" | "moderate" | "severe";
    location: string;
    confidence: "low" | "medium" | "high";
  }>;
  condition_score: number;
  summary: string;
};

const PHOTO_ANALYSIS_PROMPT = (photoKind: "screen" | "back") => `You are analyzing a photo submitted for a mobile phone insurance enrolment (Accidental Damage Protection). The customer was asked to photograph their phone in a mirror.

Photo type: ${photoKind === "screen" ? "screen-side (front of device facing mirror)" : "back-side (back of device facing mirror)"}

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
- MIRROR IMAGE: This photo is a mirror reflection, so left and right are REVERSED. When reporting "location" in damage entries, describe the location from the user's perspective holding the device normally (NOT from how it appears in the photo). If damage appears on the RIGHT side of the device in the image, report it as the "LEFT" side (because the mirror has flipped it). Top and bottom are unchanged. Use "top-left corner", "bottom-right edge", etc., referring to the device's actual orientation, not the mirrored view.
- This is for INSURANCE ENROLMENT. Missing pre-existing damage costs the insurer money. Prefer false-positive over false-negative for ANY damage detection.
- CRACKS: any visible line, fracture, or break in the glass surface — even a single hairline — must be reported as a crack (screen_crack or back_glass_crack), NOT as a scratch. If unsure between crack and scratch, classify as crack with medium confidence.
- A reflection on glass is NOT a crack. Cracks have actual line patterns through the glass surface, often originating from an impact point.
- SCRATCHES are surface marks that don't penetrate the glass — they show no spider pattern or impact origin.
- "phone_case_visible": Default to FALSE. Only set TRUE if you are highly confident a protective case is fitted. Specific things that are NOT a case (return FALSE for these):
  • A hand, fingers, or palm wrapping around the device — that's the user holding their phone, not a case.
  • The phone's own back panel finish — modern iPhones (15 Pro / 16 Pro / 17 Pro) have titanium frames and matte/textured glass backs that can look distinct from the screen side.
  • IMPORTANT — iPhone 17 Pro and 17 Pro Max back design: these models have a LARGE HORIZONTAL "camera plateau" that spans almost the FULL WIDTH of the device's upper back third. The plateau contains the three cameras + flash + LiDAR and is a DIFFERENT COLOUR / FINISH from the lower portion of the back panel by design (often satin/matte on the plateau vs. a different texture below). This two-tone back is the native iPhone 17 Pro design, NOT a case. Do not interpret the colour change between the upper plateau and lower back as a case seam.
  • Earlier iPhone Pro models (15/16 Pro) and Samsung Galaxy S/Ultra models have smaller square or rectangular camera bumps that are also part of the device.
  • A clear screen protector on the front.
  Return TRUE only when you see ALL of: (a) a clear seam/border WRAPPING AROUND THE EDGES of the device where case material ends and device begins (a seam across only the back face is NOT enough — case seams wrap to the side rails), AND (b) case-specific features like raised port cutouts, button covers, or material that extends visibly over the device's corners and edges. When in real doubt, return FALSE — false-positives frustrate users with bare phones.
- A clear screen protector on the FRONT is NOT a case. Only worry about cases on the back/edges.
- "is_fold_phone_closed": Default to FALSE. This must ONLY be true when the device is clearly a fold/flip phone (Z Fold, Z Flip, Razr, Pixel Fold etc.) AND is in the closed/folded state. Signs of CLOSED: you can see two separate panels folded onto each other at an angle, OR you can see only a small external "cover" screen with the main device folded behind it, OR you can see the device folded in half like a clamshell. An OPEN fold phone shows a SINGLE large continuous screen (often with a faint horizontal or vertical crease line down the middle of the screen — this crease is NORMAL and means the device is OPEN, not closed). A visible crease alone is NOT evidence of being closed. If unsure, return FALSE.
- For ${photoKind === "back" ? "BACK photos: this is the critical one for case detection. Look for material covering the device back that has a different colour, texture, or edge profile than the device body itself." : "SCREEN photos: examine front glass carefully for ANY crack lines, even small ones — they are the most common pre-existing damage."}
- "condition_score": 10 = pristine, 7-9 = minor wear (scratches only), 4-6 = visible damage including any crack, 1-3 = heavily damaged.

Output only the JSON.`;

async function analyzePhotoGemini(
  imageBytes: Uint8Array,
  photoKind: "screen" | "back",
  signal: AbortSignal
): Promise<PhotoAnalysis> {
  const creds = JSON.parse(GCP_CREDENTIALS);
  const token = await getGcpAccessToken();
  const project = creds.project_id;
  // Vertex AI route (uses our service account token):
  const GEMINI_MODEL = "gemini-2.5-flash";
  const vertexUrl = `https://us-central1-aiplatform.googleapis.com/v1/projects/${project}/locations/us-central1/publishers/google/models/${GEMINI_MODEL}:generateContent`;
  const b64 = imageBytesToBase64(imageBytes);

  const resp = await fetch(vertexUrl, {
    method: "POST",
    signal,
    headers: {
      "Authorization": `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      contents: [{
        role: "user",
        parts: [
          { inline_data: { mime_type: "image/jpeg", data: b64 } },
          { text: PHOTO_ANALYSIS_PROMPT(photoKind) },
        ],
      }],
      generationConfig: {
        temperature: 0.1,
        response_mime_type: "application/json",
      },
    }),
  });

  if (!resp.ok) {
    throw new Error(`Gemini failed: ${resp.status} ${await resp.text()}`);
  }
  const data = await resp.json();
  const text = data?.candidates?.[0]?.content?.parts?.[0]?.text ?? "";
  // Strip code fences if Gemini added them
  const cleaned = text.replace(/^```json\s*/i, "").replace(/```$/m, "").trim();
  return JSON.parse(cleaned) as PhotoAnalysis;
}

async function analyzePhoto(
  imageBytes: Uint8Array,
  photoKind: "screen" | "back",
  signal: AbortSignal
): Promise<PhotoAnalysis> {
  if (VISION_PROVIDER === "gemini") {
    return analyzePhotoGemini(imageBytes, photoKind, signal);
  }
  throw new Error(`Provider ${VISION_PROVIDER} not implemented`);
}

// Apply rejection rules — returns null if accepted, error string if rejected
function evaluatePhotoAnalysis(
  analysis: PhotoAnalysis,
  photoKind: "screen" | "back"
): { rejected: boolean; reason?: string; user_message?: string } {
  if (!analysis.is_phone_in_mirror) {
    return {
      rejected: true,
      reason: "not_phone_in_mirror",
      user_message: "We couldn't see your phone in a mirror. Please retake the photo with your phone facing a mirror.",
    };
  }
  if (analysis.photo_quality === "unusable") {
    return {
      rejected: true,
      reason: "photo_unusable",
      user_message: `Photo isn't clear enough: ${analysis.photo_quality_reason}. Please retake in better lighting.`,
    };
  }
  if (analysis.device_visibility === "obscured") {
    return {
      rejected: true,
      reason: "device_obscured",
      user_message: "Make sure your whole phone is visible in the mirror, not covered by your fingers or anything else.",
    };
  }
  if (photoKind === "back" && analysis.phone_case_visible) {
    return {
      rejected: true,
      reason: "phone_case_on",
      user_message: "Please remove your phone case and try again.",
    };
  }
  // Fold-closed check only on SCREEN photo. The back of an open fold phone has a
  // visible hinge that the LLM frequently misreads as "folded" — but the screen
  // photo has already verified the device is open by this point.
  if (photoKind === "screen" && analysis.is_fold_phone_closed) {
    return {
      rejected: true,
      reason: "fold_phone_closed",
      user_message: "Please open your phone fully (unfold it) before taking the photo.",
    };
  }
  // Damage rejection — for ADP we prefer false-positive over false-negative.
  // Reject any cracks/structural damage with medium-or-better confidence,
  // OR any high-confidence damage of any severity.
  const rejectableDamage = (analysis.damage || []).find((d) => {
    const isCriticalType = d.type === "screen_crack" || d.type === "back_glass_crack" || d.type === "structural_damage";
    if (isCriticalType && d.confidence !== "low") return true;  // catches any crack with med+ confidence
    if (d.confidence === "high" && d.severity !== "minor") return true;  // catches high-conf scratches/dents too
    return false;
  });
  if (rejectableDamage) {
    return {
      rejected: true,
      reason: "pre_existing_damage",
      user_message: `We detected pre-existing damage (${rejectableDamage.type.replace(/_/g, " ")}, ${rejectableDamage.location}). This device is not eligible for enrolment.`,
    };
  }
  return { rejected: false };
}

// ============================================================
// Main handler
// ============================================================
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE);
  let uploadedPath: string | null = null;
  let uploadedBucket: string | null = null;

  try {
    const form = await req.formData();
    const sessionToken = String(form.get("session_token") ?? "");
    const kind = String(form.get("kind") ?? "");
    const file = form.get("file") as File | null;

    if (!sessionToken || !kind || !file) {
      return json({ error: "Missing session_token, kind, or file" }, 400);
    }
    if (!["imei", "screen", "back"].includes(kind)) {
      return json({ error: "Invalid kind" }, 400);
    }
    if (file.size > 10 * 1024 * 1024) {
      return json({ error: "File too large (max 10MB)" }, 413);
    }

    // Client metadata for audit log + rate limiting. IP may be null if the
    // proxy strips x-forwarded-for; user_agent should always be present.
    const ip = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim()
      || req.headers.get("x-real-ip");
    const userAgent = req.headers.get("user-agent") || null;

    // Validate session
    const { data: session, error: sessionErr } = await supabase
      .from("sessions")
      .select("id, partner_id, expires_at, status")
      .eq("token", sessionToken)
      .single();
    if (sessionErr || !session) return json({ error: "Session not found" }, 401);
    if (new Date(session.expires_at) < new Date()) return json({ error: "Session expired" }, 401);
    // Terminal sessions (complete / failed) accept no more uploads. Without this
    // a rejected-damage photo could still log against a completed session and
    // confuse the audit log.
    if (session.status === "complete" || session.status === "failed" || session.status === "expired") {
      return json({ error: `Session is terminal (status=${session.status})` }, 409);
    }

    // Rate limits
    // Rate-limit by IP when visible, else per-session (so a tunnel/shared-IP demo isn't
    // throttled under one global "0.0.0.0" bucket). Demo-tuned caps; revisit for prod.
    const rlKey = ip ? ip : `sess:${sessionToken}`;
    const rlLimit = ip ? 60 : 30;
    const { data: ipOk } = await supabase.rpc("rl_check_and_increment", {
      p_key: rlKey, p_per_minute_limit: rlLimit,
    });
    if (ipOk === false) return json({ error: "Rate limit exceeded" }, 429);
    const quotaKind = kind === "imei" ? "imei" : "photo";
    const { data: quotaOk } = await supabase.rpc("session_check_upload_quota", {
      p_token: sessionToken, p_kind: quotaKind,
    });
    if (quotaOk === false) {
      return json({ error: "Upload quota exceeded for this session" }, 429);
    }

    // Upload to storage
    const bucket = kind === "imei" ? "imei_screenshots" : "condition_photos";
    const path = `${session.id}/${kind}.jpg`;
    uploadedBucket = bucket;
    uploadedPath = path;
    const fileBytes = new Uint8Array(await file.arrayBuffer());
    const { error: uploadErr } = await supabase.storage.from(bucket).upload(path, fileBytes, {
      upsert: true, contentType: "image/jpeg",
    });
    if (uploadErr) throw new Error(`Storage upload failed: ${uploadErr.message}`);

    // ===== IMEI path =====
    if (kind === "imei") {
      let extractedImei: string | null = null;
      let imeiValid = false;
      let ocrError: string | null = null;

      try {
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 10000); // raised 7->10s (prod 0763506)
        const ocrText = await visionTextDetection(fileBytes, controller.signal);
        clearTimeout(timeoutId);
        const result = extractImei(ocrText);
        extractedImei = result.imei;
        imeiValid = result.valid;
      } catch (e) {
        ocrError = e instanceof Error ? e.message : "OCR failed";
        console.error("OCR error:", ocrError);
      }

      // No IMEI extracted. Split infra failure from a genuine no-read (prod G-27/G-28):
      // an OCR timeout/outage must NOT burn the quota or count as an attempt.
      if (!extractedImei) {
        await supabase.storage.from(bucket).remove([path]).catch(() => {});
        if (ocrError) {
          // Infra failure: give the consumed slot back and label it non-counting.
          await supabase.rpc("session_refund_upload_quota", { p_token: sessionToken, p_kind: "imei" });
          return json({
            rejected: true,
            reason: "analysis_failed",
            user_message: "We couldn't read your IMEI right now. Please try again in a moment.",
            ocr_error: ocrError,
          }, 422);
        }
        return json({
          rejected: true,
          reason: "imei_not_readable",
          user_message: "We couldn't read an IMEI number on this screenshot. Make sure you dialed *#06# and captured the IMEI screen, then try again.",
          ocr_error: ocrError,
        }, 422);
      }

      // Record success
      const { error: dbErr } = await supabase.from("sessions").update({
        imei_screenshot_path: path,
        imei_extracted: extractedImei,
        imei_valid: imeiValid,
      }).eq("id", session.id);
      if (dbErr) throw new Error(`DB update failed: ${dbErr.message}`);

      await supabase.from("audit_log").insert({
        session_id: session.id,
        partner_id: session.partner_id,
        event_type: "imei_uploaded",
        actor_type: "customer",
        event_data: { size: file.size, path, ocr_valid: imeiValid },
        ip_address: ip,
        user_agent: userAgent,
      });

      return json({ success: true, path, imei: extractedImei, imei_valid: imeiValid });
    }

    // ===== Photo path (screen | back) =====
    let analysis: PhotoAnalysis | null = null;
    let analysisError: string | null = null;
    try {
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), 22000); // raised 12->22s to cover Gemini's 13-14s slow tail (prod 0763506)
      analysis = await analyzePhoto(fileBytes, kind as "screen" | "back", controller.signal);
      clearTimeout(timeoutId);
    } catch (e) {
      analysisError = e instanceof Error ? e.message : "Analysis failed";
      console.error("Photo analysis error:", analysisError);
    }

    // If analysis errored (timeout / API outage), DO NOT accept silently.
    // For ADP, every photo must be analyzed. Delete the upload and ask user to retry.
    if (!analysis) {
      await supabase.storage.from(bucket).remove([path]).catch(() => {});
      await supabase.from("audit_log").insert({
        session_id: session.id,
        partner_id: session.partner_id,
        event_type: "photo_analysis_failed",
        actor_type: "system",
        event_data: { slot: kind, size: file.size, error: analysisError },
        ip_address: ip,
        user_agent: userAgent,
      });
      // Infra failure ate a quota slot upstream — refund it so timeouts don't lock the session.
      await supabase.rpc("session_refund_upload_quota", { p_token: sessionToken, p_kind: "photo" });
      return json({
        rejected: true,
        reason: "analysis_failed",
        user_message: "We couldn't check your photo right now. Please try again in a moment.",
        analysis_error: analysisError,
      }, 422);
    }

    // Apply rejection rules
    const verdict = evaluatePhotoAnalysis(analysis, kind as "screen" | "back");
    if (verdict.rejected) {
      if (verdict.reason === "pre_existing_damage") {
        // KEEP the photo as evidence — partner needs to review it.
        // Mark photo row with status, mark session as failed permanently.
        const { error: photoErr } = await supabase.from("photos").upsert({
          session_id: session.id,
          slot: kind,
          storage_path: path,
          size_bytes: file.size,
          mime_type: "image/jpeg",
          status: "rejected_damage",
        }, { onConflict: "session_id,slot" });
        if (photoErr) console.error("Photo record (rejected_damage) failed:", photoErr);

        // Mark session as terminally failed — no retries, can't be reopened
        const { error: sessionErr } = await supabase.from("sessions").update({
          status: "failed",
          stage2_result: "fail",
          overall_result: "fail",
          stage2_completed_at: new Date().toISOString(),
        }).eq("id", session.id);
        if (sessionErr) console.error("Session-failed update failed:", sessionErr);
      } else {
        // Other (remediable) rejections: clean up so user can retry
        await supabase.storage.from(bucket).remove([path]).catch(() => {});
      }

      await supabase.from("audit_log").insert({
        session_id: session.id,
        partner_id: session.partner_id,
        event_type: "photo_rejected",
        actor_type: "system",
        event_data: { slot: kind, reason: verdict.reason, analysis },
        ip_address: ip,
        user_agent: userAgent,
      });

      return json({
        rejected: true,
        reason: verdict.reason,
        user_message: verdict.user_message,
        analysis,
      }, 422);
    }

    // Accepted — record with analysis data
    const { error: dbErr } = await supabase.from("photos").upsert({
      session_id: session.id,
      slot: kind,
      storage_path: path,
      size_bytes: file.size,
      mime_type: "image/jpeg",
    }, { onConflict: "session_id,slot" });
    if (dbErr) throw new Error(`DB upsert failed: ${dbErr.message}`);

    await supabase.from("audit_log").insert({
      session_id: session.id,
      partner_id: session.partner_id,
      event_type: "photo_uploaded",
      actor_type: "customer",
      event_data: { slot: kind, size: file.size, path, analysis },
      ip_address: ip,
      user_agent: userAgent,
    });

    return json({ success: true, path, analysis });
  } catch (e) {
    console.error("Function error:", e);
    if (uploadedPath && uploadedBucket) {
      await supabase.storage.from(uploadedBucket).remove([uploadedPath]).catch(() => {});
    }
    return json({ error: e instanceof Error ? e.message : "Unknown error" }, 500);
  }
});
