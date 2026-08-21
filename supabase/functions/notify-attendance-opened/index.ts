// @ts-ignore: Deno runtime types
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
// @ts-ignore: Deno URL import
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
// @ts-ignore: Deno URL import
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

declare const Deno: any;

// ── Minimal JWT signer for service account auth ──────────────────────────────
async function getAccessToken(serviceAccount: any): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const expiry = now + 3600;

  const header = { alg: "RS256", typ: "JWT" };
  const payload = {
    iss: serviceAccount.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: serviceAccount.token_uri,
    iat: now,
    exp: expiry,
  };

  const encode = (obj: any) =>
    btoa(JSON.stringify(obj))
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=+$/, "");

  const headerB64 = encode(header);
  const payloadB64 = encode(payload);
  const signingInput = `${headerB64}.${payloadB64}`;

  // Clean up the private key
  const pemKey = serviceAccount.private_key
    .replace(/\\n/g, "\n")
    .replace("-----BEGIN RSA PRIVATE KEY-----", "-----BEGIN PRIVATE KEY-----")
    .replace("-----END RSA PRIVATE KEY-----", "-----END PRIVATE KEY-----");

  // Import the private key
  const keyData = pemKey
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\n/g, "");

  const binaryKey = Uint8Array.from(atob(keyData), (c: string) => c.charCodeAt(0));

  const cryptoKey = await crypto.subtle.importKey(
    "pkcs8",
    binaryKey,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"]
  );

  const encoder = new TextEncoder();
  const signatureBuffer = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    cryptoKey,
    encoder.encode(signingInput)
  );

  const signatureB64 = btoa(
    String.fromCharCode(...new Uint8Array(signatureBuffer))
  )
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");

  const jwt = `${signingInput}.${signatureB64}`;

  // Exchange JWT for access token
  const tokenResponse = await fetch(serviceAccount.token_uri, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}`,
  });

  const tokenData = await tokenResponse.json();

  if (!tokenData.access_token) {
    console.error("[FCM] Token exchange failed:", JSON.stringify(tokenData));
    throw new Error("Failed to get access token from Google");
  }

  return tokenData.access_token;
}

// ── Main handler ─────────────────────────────────────────────────────────────
serve(async (req: Request) => {
  try {
    const body = await req.json();
    const record = body.record;
    const oldRecord = body.old_record;

    console.log("[NOTIFY] Webhook received, status:", record?.status);

    // Only fire when status is 'active'
    if (record?.status !== "active") {
      console.log("[NOTIFY] Skipped — status is not active");
      return new Response(JSON.stringify({ skipped: true }), { status: 200 });
    }

    // If old_record already had status='active', this is just a QR token
    // rotation update — do NOT send another notification for the same session
    if (oldRecord && oldRecord.status === "active") {
      console.log("[NOTIFY] Skipped — session was already active, QR rotation only");
      return new Response(
        JSON.stringify({ skipped: "already_active" }),
        { status: 200 }
      );
    }

    const classId = record.class_id;
    const sessionId = record.id;
    const subjectId = record.subject_id;
    const periodId = record.period_id;

    // Load service account from secret
    const serviceAccountJson = Deno.env.get("FIREBASE_SERVICE_ACCOUNT");
    if (!serviceAccountJson) {
      throw new Error("FIREBASE_SERVICE_ACCOUNT secret not set");
    }
    const serviceAccount = JSON.parse(serviceAccountJson);
    const projectId = serviceAccount.project_id;

    // Supabase client with service role
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseKey);

    // Get subject name
    const { data: subjectData } = await supabase
      .from("subjects")
      .select("name")
      .eq("id", subjectId)
      .maybeSingle();
    const subjectName = subjectData?.name ?? "";

    // Get period number
    const { data: periodData } = await supabase
      .from("periods")
      .select("period_number")
      .eq("id", periodId)
      .maybeSingle();
    const periodNum = periodData?.period_number ?? "";

    // Get all students in this class
    const { data: students } = await supabase
      .from("students")
      .select("id")
      .eq("class_id", classId);

    if (!students || students.length === 0) {
      console.log("[NOTIFY] No students found for class:", classId);
      return new Response(
        JSON.stringify({ message: "No students found" }),
        { status: 200 }
      );
    }

    const studentIds = students.map((s: any) => s.id);
    console.log("[NOTIFY] Students in class:", studentIds.length);

    // Get FCM tokens for these students
    const { data: tokenRows } = await supabase
      .from("push_tokens")
      .select("fcm_token")
      .in("student_id", studentIds);

    if (!tokenRows || tokenRows.length === 0) {
      console.log("[NOTIFY] No FCM tokens found");
      return new Response(
        JSON.stringify({ message: "No tokens found" }),
        { status: 200 }
      );
    }

    // Deduplicate FCM tokens to prevent duplicate notifications on devices
    // where multiple student accounts share the same physical device/token
    const rawTokenCount = tokenRows.length;
    const uniqueTokens: string[] = [
      ...new Set<string>(
        tokenRows
          .map((row: any) => row.fcm_token as string)
          .filter((token: string) => Boolean(token && typeof token === "string" && token.trim().length > 0))
      ),
    ];

    console.log(
      `[NOTIFY] Token lookup: ${rawTokenCount} raw token row(s), ${uniqueTokens.length} unique device token(s)`
    );

    if (uniqueTokens.length === 0) {
      console.log("[NOTIFY] No valid unique FCM tokens found after deduplication");
      return new Response(
        JSON.stringify({ message: "No valid tokens found" }),
        { status: 200 }
      );
    }

    console.log("[NOTIFY] Sending to", uniqueTokens.length, "unique device(s)");

    // Get OAuth2 access token
    const accessToken = await getAccessToken(serviceAccount);

    // Send notification to each unique token using FCM V1 API
    const fcmUrl = `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`;

    const results = await Promise.allSettled(
      uniqueTokens.map(async (token: string) => {
        const fcmPayload = {
          message: {
            token: token,
            android: {
              priority: "high",
            },
            data: {
              type: "attendance_opened",
              session_id: String(sessionId),
              class_id: String(classId),
              subject_name: String(subjectName ?? ""),
              period_number:
                periodNum != null && periodNum !== "" ? String(periodNum) : "",
            },
          },
        };

        const response = await fetch(fcmUrl, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${accessToken}`,
          },
          body: JSON.stringify(fcmPayload),
        });

        const result = await response.json();
        if (!response.ok) {
          console.error("[FCM] Send failed for token:", result);
          throw new Error(result.error?.message || "FCM send failed");
        }
        return result;
      })
    );

    const succeeded = results.filter((r) => r.status === "fulfilled").length;
    const failed = results.filter((r) => r.status === "rejected").length;

    console.log(
      `[NOTIFY] Done — raw rows: ${rawTokenCount}, unique devices: ${uniqueTokens.length}, sent: ${succeeded}, failed: ${failed}`
    );

    return new Response(
      JSON.stringify({
        success: true,
        raw_tokens: rawTokenCount,
        unique_tokens: uniqueTokens.length,
        sent: succeeded,
        failed,
      }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    );
  } catch (error) {
    console.error("[NOTIFY] Fatal error:", error);
    return new Response(
      JSON.stringify({ error: String(error) }),
      { status: 500 }
    );
  }
});
