// ============================================================
// Nexacore Device Check — Edge Function: upload-and-process
// ============================================================
// Accepts multipart/form-data with:
//   session_token: string  (the URL token)
//   kind: "imei" | "screen" | "back"
//   file: image binary
//
// Validates session, uploads to storage with service_role, runs Vision OCR
// for IMEI uploads, records metadata in DB. Idempotent on (session_id, kind).
//
// Deploy via Supabase Dashboard → Edge Functions → New Function.
// Function name: upload-and-process
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const GCP_CREDENTIALS = Deno.env.get("GCP_VISION_CREDENTIALS")!;

// CORS — locked to GitHub Pages origin once stable; using * during demo development
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
// Google Vision OAuth2 (JWT bearer flow)
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

  // Import the PKCS#8 private key
  const pemBody = creds.private_key
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s/g, "");
  const derBytes = Uint8Array.from(atob(pemBody), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    "pkcs8",
    derBytes,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sigBuffer = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
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
// Vision API TEXT_DETECTION
// ============================================================
async function visionTextDetection(
  imageBytes: Uint8Array,
  signal: AbortSignal
): Promise<string> {
  const token = await getGcpAccessToken();
  // Convert to base64 in chunks to avoid stack overflow on large images
  let binary = "";
  const chunkSize = 32768;
  for (let i = 0; i < imageBytes.length; i += chunkSize) {
    binary += String.fromCharCode(...imageBytes.subarray(i, i + chunkSize));
  }
  const b64Image = btoa(binary);

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

// ============================================================
// IMEI extraction + Luhn validation
// ============================================================
function luhnCheck(digits: string): boolean {
  let sum = 0;
  let alt = false;
  for (let i = digits.length - 1; i >= 0; i--) {
    let d = parseInt(digits[i], 10);
    if (alt) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
    alt = !alt;
  }
  return sum % 10 === 0;
}

function extractImei(ocrText: string): { imei: string | null; valid: boolean } {
  // Find 15-digit candidates (allowing spaces/dashes/dots between digits)
  const candidates = ocrText.match(/(?:\d[\s.\-]?){15}/g) ?? [];
  for (const candidate of candidates) {
    const digits = candidate.replace(/\D/g, "");
    if (digits.length === 15 && luhnCheck(digits)) {
      return { imei: digits, valid: true };
    }
  }
  // Fallback: return any 15-digit run even without Luhn (some carriers issue non-standard IMEIs)
  for (const candidate of candidates) {
    const digits = candidate.replace(/\D/g, "");
    if (digits.length === 15) {
      return { imei: digits, valid: false };
    }
  }
  return { imei: null, valid: false };
}

// ============================================================
// Main handler
// ============================================================
Deno.serve(async (req) => {
  // CORS preflight
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE);

  let uploadedPath: string | null = null;
  let uploadedBucket: string | null = null;

  try {
    // Parse multipart form
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

    // Validate session
    const { data: session, error: sessionErr } = await supabase
      .from("sessions")
      .select("id, partner_id, expires_at, status")
      .eq("token", sessionToken)
      .single();

    if (sessionErr || !session) {
      return json({ error: "Session not found" }, 401);
    }
    if (new Date(session.expires_at) < new Date()) {
      return json({ error: "Session expired" }, 401);
    }

    // Upload to storage
    const bucket = kind === "imei" ? "imei_screenshots" : "condition_photos";
    const path = `${session.id}/${kind}.jpg`;
    uploadedBucket = bucket;
    uploadedPath = path;

    const fileBytes = new Uint8Array(await file.arrayBuffer());
    const { error: uploadErr } = await supabase.storage
      .from(bucket)
      .upload(path, fileBytes, {
        upsert: true,
        contentType: "image/jpeg",
      });
    if (uploadErr) {
      throw new Error(`Storage upload failed: ${uploadErr.message}`);
    }

    // OCR for IMEI uploads (graceful fallback if Vision fails)
    let extractedImei: string | null = null;
    let imeiValid = false;
    let ocrError: string | null = null;

    if (kind === "imei") {
      try {
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 5000);
        const ocrText = await visionTextDetection(fileBytes, controller.signal);
        clearTimeout(timeoutId);
        const result = extractImei(ocrText);
        extractedImei = result.imei;
        imeiValid = result.valid;
      } catch (e) {
        ocrError = e instanceof Error ? e.message : "OCR failed";
        console.error("OCR error:", ocrError);
      }
    }

    // Record in DB
    if (kind === "imei") {
      const { error: dbErr } = await supabase
        .from("sessions")
        .update({
          imei_screenshot_path: path,
          imei_extracted: extractedImei,
          imei_valid: imeiValid,
        })
        .eq("id", session.id);
      if (dbErr) throw new Error(`DB update failed: ${dbErr.message}`);

      await supabase.from("audit_log").insert({
        session_id: session.id,
        partner_id: session.partner_id,
        event_type: "imei_uploaded",
        actor_type: "customer",
        event_data: {
          size: file.size,
          path,
          ocr_extracted: extractedImei !== null,
          ocr_valid: imeiValid,
          ocr_error: ocrError,
        },
      });
    } else {
      const { error: dbErr } = await supabase
        .from("photos")
        .upsert({
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
        event_data: { slot: kind, size: file.size, path },
      });
    }

    return json({
      success: true,
      path,
      imei: extractedImei,
      imei_valid: imeiValid,
      ocr_error: ocrError,
    });
  } catch (e) {
    console.error("Function error:", e);

    // Orphan cleanup
    if (uploadedPath && uploadedBucket) {
      try {
        await supabase.storage.from(uploadedBucket).remove([uploadedPath]);
      } catch (cleanupErr) {
        console.error("Cleanup failed:", cleanupErr);
      }
    }

    const msg = e instanceof Error ? e.message : "Unknown error";
    return json({ error: msg }, 500);
  }
});
