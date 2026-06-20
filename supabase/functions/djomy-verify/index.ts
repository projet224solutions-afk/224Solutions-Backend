import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.2";
import { crypto } from "https://deno.land/std@0.190.0/crypto/mod.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const logStep = (step: string, details?: Record<string, unknown>) => {
  const detailsStr = details ? ` - ${JSON.stringify(details)}` : "";
  console.log(`[DJOMY-VERIFY] ${step}${detailsStr}`);
};

// Generate HMAC-SHA256 signature
async function generateHmacSignature(clientId: string, clientSecret: string): Promise<string> {
  const encoder = new TextEncoder();
  const keyData = encoder.encode(clientSecret);
  const messageData = encoder.encode(clientId);
  
  const key = await crypto.subtle.importKey(
    "raw",
    keyData,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  
  const signature = await crypto.subtle.sign("HMAC", key, messageData);
  const hashArray = Array.from(new Uint8Array(signature));
  return hashArray.map(b => b.toString(16).padStart(2, "0")).join("");
}

// Get Bearer token from Djomy
async function getAccessToken(clientId: string, clientSecret: string, useSandbox: boolean): Promise<string> {
  const baseUrl = useSandbox 
    ? "https://sandbox-api.djomy.africa" 
    : "https://api.djomy.africa";
  
  const signature = await generateHmacSignature(clientId, clientSecret);
  const xApiKey = `${clientId}:${signature}`;
  
  const response = await fetch(`${baseUrl}/v1/auth`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Accept": "application/json",
      "X-API-KEY": xApiKey,
    },
    body: JSON.stringify({}),
  });
  
  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(`Authentication failed: ${response.status} - ${errorText}`);
  }
  
  const data = await response.json();
  return data.accessToken;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    logStep("Function started");

    const body = await req.json();
    const { transactionId, useSandbox = false } = body;

    // Choix des identifiants selon l'environnement
    const clientId = useSandbox
      ? (Deno.env.get("JOMY_CLIENT_ID_SANDBOX") ?? Deno.env.get("JOMY_CLIENT_ID"))
      : (Deno.env.get("JOMY_CLIENT_ID_PROD") ?? Deno.env.get("JOMY_CLIENT_ID"));

    const clientSecret = useSandbox
      ? (Deno.env.get("JOMY_CLIENT_SECRET_SANDBOX") ?? Deno.env.get("JOMY_CLIENT_SECRET"))
      : (Deno.env.get("JOMY_CLIENT_SECRET_PROD") ?? Deno.env.get("JOMY_CLIENT_SECRET"));

    if (!clientId || !clientSecret) {
      throw new Error("Djomy credentials not configured");
    }

    if (!transactionId) {
      throw new Error("Transaction ID is required");
    }

    logStep("Verifying payment", { transactionId, useSandbox });

    // Get access token
    const accessToken = await getAccessToken(clientId, clientSecret, useSandbox);

    // Generate API signature
    const signature = await generateHmacSignature(clientId, clientSecret);
    const xApiKey = `${clientId}:${signature}`;

    const baseUrl = useSandbox 
      ? "https://sandbox-api.djomy.africa" 
      : "https://api.djomy.africa";

    // Get payment status from Djomy
    const response = await fetch(`${baseUrl}/v1/payments/${transactionId}/status`, {
      method: "GET",
      headers: {
        "Authorization": `Bearer ${accessToken}`,
        "X-API-KEY": xApiKey,
      },
    });

    if (!response.ok) {
      const errorText = await response.text();
      logStep("Verification error", { status: response.status, error: errorText });
      throw new Error(`Verification failed: ${response.status} - ${errorText}`);
    }

    const paymentData = await response.json();
    logStep("Payment status retrieved", paymentData);

    // Update local database
    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
      { auth: { persistSession: false } }
    );

    // Map status
    const statusMap: Record<string, string> = {
      "CREATED": "created",
      "PENDING": "pending",
      "SUCCESS": "completed",
      "FAILED": "failed",
      "CANCELLED": "cancelled",
    };

    const internalStatus = statusMap[paymentData.status] || paymentData.status?.toLowerCase() || "unknown";

    const { error: updateError } = await supabaseAdmin
      .from("djomy_payments")
      .update({
        status: internalStatus,
        response_data: paymentData,
        updated_at: new Date().toISOString(),
      })
      .eq("transaction_id", transactionId);

    if (updateError) {
      logStep("Database update error", { error: updateError.message });
    }

    return new Response(
      JSON.stringify({
        success: true,
        transactionId,
        status: internalStatus,
        originalStatus: paymentData.status,
        data: paymentData,
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      }
    );

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    logStep("ERROR", { message: errorMessage });

    // IMPORTANT: renvoyer 200 pour que le frontend lise le JSON d'erreur
    return new Response(
      JSON.stringify({ success: false, error: errorMessage }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      }
    );
  }
});
