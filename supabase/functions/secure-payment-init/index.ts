/**
 * 🔐 SECURE PAYMENT INITIALIZATION - BACKEND ONLY
 * Règles de sécurité financières absolues
 * Montants calculés côté serveur, signature HMAC-SHA256
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.2";
import { crypto } from "https://deno.land/std@0.190.0/crypto/mod.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const FEE_PERCENTAGE = 0.025; // 2.5%
const TRANSACTION_SECRET = Deno.env.get("TRANSACTION_SECRET_KEY");
if (!TRANSACTION_SECRET) throw new Error("CRITICAL: TRANSACTION_SECRET_KEY not configured");

const logStep = (step: string, details?: Record<string, unknown>) => {
  const detailsStr = details ? ` - ${JSON.stringify(details)}` : "";
  console.log(`[SECURE-PAYMENT] ${step}${detailsStr}`);
};

// 🔐 Generate HMAC-SHA256 signature
async function generateSignature(transactionId: string, totalAmount: number): Promise<string> {
  const encoder = new TextEncoder();
  const data = encoder.encode(`${transactionId}${totalAmount}`);
  const keyData = encoder.encode(TRANSACTION_SECRET);
  
  const key = await crypto.subtle.importKey(
    "raw",
    keyData,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  
  const signature = await crypto.subtle.sign("HMAC", key, data);
  const hashArray = Array.from(new Uint8Array(signature));
  return hashArray.map(b => b.toString(16).padStart(2, "0")).join("");
}

// 🔐 Verify signature
async function verifySignature(transactionId: string, totalAmount: number, providedSignature: string): Promise<boolean> {
  const expectedSignature = await generateSignature(transactionId, totalAmount);
  return expectedSignature === providedSignature;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    logStep("Secure payment initialization started");

    // 🔐 Initialize Supabase with service role for secure operations
    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
      { auth: { persistSession: false } }
    );

    // 🔐 Verify user authentication
    const supabaseClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? ""
    );

    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      logStep("ERROR: No authorization header");
      return new Response(
        JSON.stringify({ success: false, error: "UNAUTHORIZED", message: "Authentification requise" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 401 }
      );
    }

    const token = authHeader.replace("Bearer ", "");
    const { data: userData, error: userError } = await supabaseClient.auth.getUser(token);
    
    if (userError || !userData.user) {
      logStep("ERROR: Invalid token");
      return new Response(
        JSON.stringify({ success: false, error: "UNAUTHORIZED", message: "Token invalide" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 401 }
      );
    }

    const userId = userData.user.id;
    logStep("User authenticated", { userId });

    // 🔐 Get request body - ONLY requested_amount is accepted from frontend
    const body = await req.json();
    const { 
      requested_amount, 
      interface_type = "client",
      transaction_type = "deposit",
      payment_method = "OM"
    } = body;

    // 🔐 Validate requested amount
    if (!requested_amount || typeof requested_amount !== "number" || requested_amount <= 0) {
      logStep("ERROR: Invalid amount", { requested_amount });
      return new Response(
        JSON.stringify({ success: false, error: "INVALID_AMOUNT", message: "Montant invalide" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 400 }
      );
    }

    // 🔐 Check if user is blocked
    const { data: securityFlags } = await supabaseAdmin
      .from("user_security_flags")
      .select("is_blocked, blocked_reason")
      .eq("user_id", userId)
      .single();

    if (securityFlags?.is_blocked) {
      logStep("ERROR: User is blocked", { userId, reason: securityFlags.blocked_reason });
      
      // Log the attempt
      await supabaseAdmin.from("financial_audit_logs").insert({
        user_id: userId,
        action_type: "attempt",
        description: "Tentative de paiement par utilisateur bloqué",
        is_suspicious: true,
        security_flags: ["blocked_user_attempt"],
        ip_address: req.headers.get("x-forwarded-for") || req.headers.get("x-real-ip"),
        user_agent: req.headers.get("user-agent")
      });

      return new Response(
        JSON.stringify({ 
          success: false, 
          error: "USER_BLOCKED", 
          message: "Compte bloqué pour raisons de sécurité" 
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 403 }
      );
    }

    // 🔐 BACKEND CALCULATES ALL AMOUNTS (never trust frontend)
    const feeAmount = Math.round(requested_amount * FEE_PERCENTAGE * 100) / 100;
    const totalAmount = requested_amount + feeAmount;
    const netAmount = requested_amount;

    logStep("Amounts calculated by backend", {
      requested: requested_amount,
      fee: feeAmount,
      total: totalAmount,
      net: netAmount
    });

    // 🔐 Generate unique transaction ID
    const transactionId = crypto.randomUUID();

    // 🔐 Generate HMAC-SHA256 signature
    const signature = await generateSignature(transactionId, totalAmount);
    
    logStep("Signature generated", { 
      transactionId, 
      signatureLength: signature.length 
    });

    // 🔐 Create immutable transaction record
    const ipAddress = req.headers.get("x-forwarded-for") || req.headers.get("x-real-ip") || null;
    const userAgent = req.headers.get("user-agent") || null;

    const { error: insertError } = await supabaseAdmin
      .from("secure_transactions")
      .insert({
        id: transactionId,
        user_id: userId,
        requested_amount: requested_amount,
        fee_percentage: FEE_PERCENTAGE,
        fee_amount: feeAmount,
        total_amount: totalAmount,
        net_amount: netAmount,
        signature_hash: signature,
        transaction_type: transaction_type,
        interface_type: interface_type,
        payment_method: payment_method,
        status: "pending",
        payment_provider: "djomy",
        ip_address: ipAddress,
        user_agent: userAgent
      });

    if (insertError) {
      logStep("ERROR: Failed to create transaction", { error: insertError.message });
      return new Response(
        JSON.stringify({ success: false, error: "TRANSACTION_CREATION_FAILED", message: "Erreur création transaction" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 500 }
      );
    }

    // 🔐 Create audit log
    await supabaseAdmin.from("financial_audit_logs").insert({
      transaction_id: transactionId,
      user_id: userId,
      action_type: "create",
      description: `Transaction créée - Total: ${totalAmount} GNF`,
      new_status: "pending",
      request_data: {
        requested_amount,
        fee_amount: feeAmount,
        total_amount: totalAmount,
        net_amount: netAmount,
        interface_type,
        payment_method
      },
      ip_address: ipAddress,
      user_agent: userAgent
    });

    logStep("Transaction created successfully", { transactionId });

    // 🔐 Return transaction details for payment
    return new Response(
      JSON.stringify({
        success: true,
        transaction_id: transactionId,
        requested_amount: requested_amount,
        fee_amount: feeAmount,
        fee_percentage: FEE_PERCENTAGE * 100,
        total_amount: totalAmount,
        net_amount: netAmount,
        signature: signature,
        status: "pending",
        message: "Transaction créée avec succès. Procédez au paiement."
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 }
    );

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    logStep("CRITICAL ERROR", { message: errorMessage });
    
    return new Response(
      JSON.stringify({ success: false, error: "INTERNAL_ERROR", message: "Erreur serveur" }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 500 }
    );
  }
});
