/**
 * 🔐 HMAC-SHA256 REQUEST GUARD V2 - Sécurité niveau fintech
 * 
 * Vérifie chaque requête via:
 * - X-API-KEY: identifiant client
 * - X-SIGNATURE: HMAC-SHA256(METHOD + PATH + BODY + TIMESTAMP + NONCE)
 * - X-TIMESTAMP: horodatage (max 5 min)
 * - X-NONCE: unicité anti-replay
 * - Idempotency-Key: anti-double-transaction
 * 
 * 224Solutions - Sécurité financière absolue
 */

import { crypto } from "https://deno.land/std@0.190.0/crypto/mod.ts";

// ═══════════════════════════════════════════════════════
// Configuration
// ═══════════════════════════════════════════════════════

const MAX_TIMESTAMP_DRIFT_MS = 5 * 60 * 1000; // 5 minutes
const NONCE_TTL_MS = 5 * 60 * 1000; // 5 minutes
const IDEMPOTENCY_TTL_MS = 24 * 60 * 60 * 1000; // 24h

// In-memory stores (per edge function instance)
// In production at scale, replace with Redis/Upstash
const usedNonces = new Map<string, number>();
const idempotencyStore = new Map<string, { response: string; timestamp: number }>();

// Cleanup expired entries every 60s
let lastCleanup = Date.now();
function cleanupStores() {
  const now = Date.now();
  if (now - lastCleanup < 60_000) return;
  lastCleanup = now;
  for (const [nonce, ts] of usedNonces) {
    if (now - ts > NONCE_TTL_MS) usedNonces.delete(nonce);
  }
  for (const [key, val] of idempotencyStore) {
    if (now - val.timestamp > IDEMPOTENCY_TTL_MS) idempotencyStore.delete(key);
  }
}

// ═══════════════════════════════════════════════════════
// Core HMAC functions
// ═══════════════════════════════════════════════════════

const encoder = new TextEncoder();

async function hmacSha256(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sig = await crypto.subtle.sign("HMAC", key, encoder.encode(message));
  return Array.from(new Uint8Array(sig))
    .map(b => b.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * Timing-safe comparison to prevent timing attacks
 */
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let result = 0;
  for (let i = 0; i < a.length; i++) {
    result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return result === 0;
}

// ═══════════════════════════════════════════════════════
// Guard Result
// ═══════════════════════════════════════════════════════

export interface HmacGuardResult {
  valid: boolean;
  error?: string;
  code?: "MISSING_HEADERS" | "INVALID_API_KEY" | "TIMESTAMP_EXPIRED" | "NONCE_REUSED" | "SIGNATURE_INVALID" | "IDEMPOTENCY_DUPLICATE";
  cachedResponse?: string; // For idempotency hits
}

// ═══════════════════════════════════════════════════════
// Main Guard Function
// ═══════════════════════════════════════════════════════

/**
 * 🔐 Validates HMAC-signed request
 * 
 * @param req - The incoming request
 * @param rawBody - The raw body string (already read from request)
 * @param options - Optional overrides
 */
export async function validateHmacRequest(
  req: Request,
  rawBody: string,
  options?: {
    apiKeyEnvVar?: string;
    secretEnvVar?: string;
    maxDriftMs?: number;
    skipNonceCheck?: boolean;
    checkIdempotency?: boolean; // Enable anti-double-transaction
  }
): Promise<HmacGuardResult> {
  const apiKeyEnv = options?.apiKeyEnvVar ?? "PAYPAL_CLIENT_ID";
  const secretEnv = options?.secretEnvVar ?? "TRANSACTION_SECRET_KEY";
  const maxDrift = options?.maxDriftMs ?? MAX_TIMESTAMP_DRIFT_MS;

  // 1. Extract headers
  const apiKey = req.headers.get("x-api-key");
  const signature = req.headers.get("x-signature");
  const timestamp = req.headers.get("x-timestamp");
  const nonce = req.headers.get("x-nonce");

  if (!apiKey || !signature || !timestamp || !nonce) {
    return {
      valid: false,
      error: "Missing required security headers: x-api-key, x-signature, x-timestamp, x-nonce",
      code: "MISSING_HEADERS"
    };
  }

  // 2. Validate API key
  const expectedApiKey = Deno.env.get(apiKeyEnv);
  if (!expectedApiKey || !timingSafeEqual(apiKey, expectedApiKey)) {
    console.warn(`🚨 [HMAC-GUARD] Invalid API key attempt`);
    return {
      valid: false,
      error: "Invalid API key",
      code: "INVALID_API_KEY"
    };
  }

  // 3. Validate timestamp (anti-replay window)
  const requestTime = parseInt(timestamp, 10);
  if (isNaN(requestTime)) {
    return {
      valid: false,
      error: "Invalid timestamp format",
      code: "TIMESTAMP_EXPIRED"
    };
  }

  const now = Date.now();
  if (Math.abs(now - requestTime) > maxDrift) {
    console.warn(`🚨 [HMAC-GUARD] Timestamp expired: drift=${Math.abs(now - requestTime)}ms`);
    return {
      valid: false,
      error: "Request timestamp expired (max 5 minutes)",
      code: "TIMESTAMP_EXPIRED"
    };
  }

  // 4. Validate nonce uniqueness (anti-replay)
  if (!options?.skipNonceCheck) {
    cleanupStores();
    if (usedNonces.has(nonce)) {
      console.warn(`🚨 [HMAC-GUARD] Nonce reused: ${nonce.substring(0, 8)}...`);
      return {
        valid: false,
        error: "Nonce already used (replay attack detected)",
        code: "NONCE_REUSED"
      };
    }
    usedNonces.set(nonce, now);
  }

  // 5. Reconstruct and verify signature
  const url = new URL(req.url);
  const signaturePayload = `${req.method}${url.pathname}${rawBody}${timestamp}${nonce}`;

  const secret = Deno.env.get(secretEnv);
  if (!secret) {
    console.error(`🔴 [HMAC-GUARD] ${secretEnv} not configured`);
    return {
      valid: false,
      error: "Server configuration error",
      code: "SIGNATURE_INVALID"
    };
  }

  const expectedSignature = await hmacSha256(secret, signaturePayload);

  if (!timingSafeEqual(signature.toLowerCase(), expectedSignature.toLowerCase())) {
    console.warn(`🚨 [HMAC-GUARD] Signature mismatch`);
    return {
      valid: false,
      error: "Invalid request signature",
      code: "SIGNATURE_INVALID"
    };
  }

  // 6. Idempotency check (anti-double-transaction)
  if (options?.checkIdempotency) {
    const idempotencyKey = req.headers.get("idempotency-key");
    if (idempotencyKey && idempotencyStore.has(idempotencyKey)) {
      const cached = idempotencyStore.get(idempotencyKey)!;
      console.warn(`🔁 [HMAC-GUARD] Idempotency hit: ${idempotencyKey.substring(0, 8)}...`);
      return {
        valid: false,
        error: "Duplicate transaction detected",
        code: "IDEMPOTENCY_DUPLICATE",
        cachedResponse: cached.response,
      };
    }
  }

  return { valid: true };
}

// ═══════════════════════════════════════════════════════
// Idempotency: Store successful response
// ═══════════════════════════════════════════════════════

export function storeIdempotencyResponse(req: Request, responseBody: string) {
  const idempotencyKey = req.headers.get("idempotency-key");
  if (idempotencyKey) {
    idempotencyStore.set(idempotencyKey, {
      response: responseBody,
      timestamp: Date.now(),
    });
  }
}

// ═══════════════════════════════════════════════════════
// Helper: Create error response
// ═══════════════════════════════════════════════════════

export function hmacErrorResponse(
  result: HmacGuardResult,
  corsHeaders: Record<string, string>
): Response {
  // If idempotency duplicate, return cached response
  if (result.code === "IDEMPOTENCY_DUPLICATE" && result.cachedResponse) {
    return new Response(result.cachedResponse, {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  return new Response(
    JSON.stringify({
      success: false,
      error: result.error,
      code: result.code,
    }),
    {
      status: 401,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    }
  );
}

// ═══════════════════════════════════════════════════════
// Fraud scoring middleware
// ═══════════════════════════════════════════════════════

export interface FraudScore {
  score: number; // 0-100, higher = more suspicious
  flags: string[];
  action: "allow" | "review" | "block";
}

export function assessFraudRisk(
  req: Request,
  body: Record<string, unknown>,
  userId: string,
): FraudScore {
  const flags: string[] = [];
  let score = 0;

  // Check amount thresholds
  const amount = Number(body.amount || 0);
  if (amount > 500000) { score += 20; flags.push("high_amount"); }
  if (amount > 2000000) { score += 30; flags.push("very_high_amount"); }

  // Check user agent
  const ua = req.headers.get("user-agent") || "";
  if (!ua || ua.length < 10) { score += 15; flags.push("suspicious_user_agent"); }
  if (ua.includes("curl") || ua.includes("wget") || ua.includes("python")) {
    score += 25; flags.push("automated_tool");
  }

  // Check for missing origin
  const origin = req.headers.get("origin");
  if (!origin) { score += 10; flags.push("no_origin_header"); }

  // Check IP
  const ip = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim();
  if (!ip) { score += 5; flags.push("no_ip"); }

  // Determine action
  let action: "allow" | "review" | "block" = "allow";
  if (score >= 60) action = "block";
  else if (score >= 30) action = "review";

  if (score > 0) {
    console.log(`🔍 [FRAUD] User ${userId.substring(0, 8)}: score=${score}, flags=[${flags.join(",")}], action=${action}`);
  }

  return { score, flags, action };
}

// ═══════════════════════════════════════════════════════
// Webhook signature verification (PayPal)
// ═══════════════════════════════════════════════════════

export async function verifyPayPalWebhook(
  req: Request,
  rawBody: string,
  webhookId: string,
): Promise<{ valid: boolean; error?: string }> {
  const transmissionId = req.headers.get("paypal-transmission-id");
  const transmissionTime = req.headers.get("paypal-transmission-time");
  const transmissionSig = req.headers.get("paypal-transmission-sig");
  const certUrl = req.headers.get("paypal-cert-url");
  const authAlgo = req.headers.get("paypal-auth-algo");

  if (!transmissionId || !transmissionTime || !transmissionSig || !certUrl || !authAlgo) {
    return { valid: false, error: "Missing PayPal webhook headers" };
  }

  // Validate cert URL is from PayPal
  try {
    const url = new URL(certUrl);
    if (!url.hostname.endsWith(".paypal.com") && !url.hostname.endsWith(".symantec.com")) {
      return { valid: false, error: "Invalid PayPal certificate URL" };
    }
  } catch {
    return { valid: false, error: "Malformed certificate URL" };
  }

  const clientId = Deno.env.get("PAYPAL_CLIENT_ID");
  const secret = Deno.env.get("PAYPAL_SECRET_KEY");
  if (!clientId || !secret) {
    return { valid: false, error: "PayPal credentials not configured" };
  }

  try {
    const tokenRes = await fetch("https://api-m.paypal.com/v1/oauth2/token", {
      method: "POST",
      headers: {
        "Authorization": `Basic ${btoa(`${clientId}:${secret}`)}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: "grant_type=client_credentials",
    });

    if (!tokenRes.ok) {
      const err = await tokenRes.text();
      return { valid: false, error: `PayPal auth failed: ${err}` };
    }

    const { access_token } = await tokenRes.json();

    const verifyRes = await fetch("https://api-m.paypal.com/v1/notifications/verify-webhook-signature", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${access_token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        auth_algo: authAlgo,
        cert_url: certUrl,
        transmission_id: transmissionId,
        transmission_sig: transmissionSig,
        transmission_time: transmissionTime,
        webhook_id: webhookId,
        webhook_event: JSON.parse(rawBody),
      }),
    });

    if (!verifyRes.ok) {
      const err = await verifyRes.text();
      return { valid: false, error: `PayPal verification failed: ${err}` };
    }

    const result = await verifyRes.json();
    if (result.verification_status !== "SUCCESS") {
      console.warn(`🚨 [PAYPAL-WEBHOOK] Verification failed: ${result.verification_status}`);
      return { valid: false, error: "PayPal signature verification failed" };
    }

    return { valid: true };
  } catch (error) {
    console.error("[PAYPAL-WEBHOOK] Verification error:", error);
    return { valid: false, error: "PayPal webhook verification error" };
  }
}

// ═══════════════════════════════════════════════════════
// Server-side signature generator (for server-to-server)
// ═══════════════════════════════════════════════════════

export async function generateRequestSignature(
  method: string,
  path: string,
  body: string,
  timestamp: string,
  nonce: string,
  secret: string,
): Promise<string> {
  const payload = `${method}${path}${body}${timestamp}${nonce}`;
  return hmacSha256(secret, payload);
}
