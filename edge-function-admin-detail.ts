// ============================================================
// Nexacore Device Check — Edge Function: admin-detail
// ============================================================
// Returns full session detail for the admin dashboard:
//   - Session metadata
//   - All diagnostic results
//   - Photos with signed URLs (1hr expiry)
//   - IMEI screenshot with signed URL
//   - Audit log
//
// Auth: admin_token (must match a partner's admin_token).
// Only returns sessions belonging to that partner.
//
// Function name when deploying: admin-detail
// Disable "Verify JWT" toggle after deploy.
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

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

const SIGNED_URL_EXPIRY_SECONDS = 3600;  // 1 hour

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE);

  try {
    const body = await req.json();
    const adminToken = String(body.admin_token ?? "");
    const sessionToken = String(body.session_token ?? "");

    if (!adminToken || adminToken.length < 10) {
      return json({ error: "Missing admin_token" }, 400);
    }
    if (!sessionToken) {
      return json({ error: "Missing session_token" }, 400);
    }

    // Authenticate admin against partners table
    const { data: partner, error: partnerErr } = await supabase
      .from("partners")
      .select("id, name, slug")
      .eq("admin_token", adminToken)
      .eq("active", true)
      .single();

    if (partnerErr || !partner) {
      return json({ error: "Unauthorized" }, 401);
    }

    // Get session — must belong to the authenticated partner
    const { data: session, error: sessionErr } = await supabase
      .from("sessions")
      .select("*")
      .eq("token", sessionToken)
      .eq("partner_id", partner.id)
      .single();

    if (sessionErr || !session) {
      return json({ error: "Session not found" }, 404);
    }

    // Fetch related data in parallel
    const [diagnosticsResp, photosResp, auditResp] = await Promise.all([
      supabase
        .from("diagnostics")
        .select("check_name, status, data, created_at")
        .eq("session_id", session.id)
        .order("check_name"),
      supabase
        .from("photos")
        .select("slot, storage_path, size_bytes, mime_type, uploaded_at")
        .eq("session_id", session.id),
      supabase
        .from("audit_log")
        .select("event_type, actor_type, event_data, created_at")
        .eq("session_id", session.id)
        .order("created_at", { ascending: false })
        .limit(50),
    ]);

    // Generate signed URL for IMEI screenshot
    let imeiSignedUrl: string | null = null;
    if (session.imei_screenshot_path) {
      const { data: signed } = await supabase.storage
        .from("imei_screenshots")
        .createSignedUrl(session.imei_screenshot_path, SIGNED_URL_EXPIRY_SECONDS);
      imeiSignedUrl = signed?.signedUrl ?? null;
    }

    // Generate signed URLs for condition photos
    const photosWithUrls = await Promise.all(
      (photosResp.data ?? []).map(async (photo) => {
        const { data: signed } = await supabase.storage
          .from("condition_photos")
          .createSignedUrl(photo.storage_path, SIGNED_URL_EXPIRY_SECONDS);
        return { ...photo, signed_url: signed?.signedUrl ?? null };
      })
    );

    // Strip raw token from response (don't echo back secrets)
    const safeSession = { ...session };
    delete safeSession.token;  // Don't include the URL token in admin payload
    // Strip full_report's stripped base64 placeholders — keep useful structure
    if (safeSession.full_report) {
      const reportStr = JSON.stringify(safeSession.full_report);
      if (reportStr.includes("[BASE64_IMAGE_STRIPPED]")) {
        // Already stripped, fine
      }
    }

    return json({
      partner: { id: partner.id, name: partner.name, slug: partner.slug },
      session: safeSession,
      diagnostics: diagnosticsResp.data ?? [],
      photos: photosWithUrls,
      audit_log: auditResp.data ?? [],
      imei_signed_url: imeiSignedUrl,
      signed_url_expires_at: new Date(Date.now() + SIGNED_URL_EXPIRY_SECONDS * 1000).toISOString(),
    });
  } catch (e) {
    console.error("admin-detail error:", e);
    const msg = e instanceof Error ? e.message : "Unknown error";
    return json({ error: msg }, 500);
  }
});
