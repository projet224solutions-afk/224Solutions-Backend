/**
 * 💳 DJOMY INIT PAYMENT - VERSION CONFORME À LA DOC OFFICIELLE
 * https://developers.djomy.africa
 * 
 * Endpoint POST /v1/payments (sans redirection)
 * Supporte: OM, MOMO, KULU (pas VISA/MC)
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.2";
import { createDjomyClient } from "../_shared/djomy-client.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const logStep = (step: string, details?: Record<string, unknown>) => {
  const timestamp = new Date().toISOString();
  const detailsStr = details ? ` - ${JSON.stringify(details)}` : "";
  console.log(`[${timestamp}] [DJOMY-INIT] ${step}${detailsStr}`);
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  const startTime = Date.now();
  
  try {
    logStep("Payment init started");

    // Parse request body
    const body = await req.json();
    const {
      amount,
      payerPhone,
      paymentMethod, // OM, MOMO, KULU
      vendorId,
      orderId,
      description,
      countryCode = "GN",
      idempotencyKey,
      returnUrl,
      cancelUrl,
      metadata = {},
      useSandbox = false, // 🧪 Mode sandbox pour les tests
    } = body;

    logStep("Request received", { amount, paymentMethod, useSandbox });

    // Input validation
    if (!amount || amount <= 0) {
      throw new Error("Montant invalide - doit être supérieur à 0");
    }
    if (!payerPhone || payerPhone.length < 8) {
      throw new Error("Numéro de téléphone invalide - minimum 8 chiffres");
    }
    if (!paymentMethod || !["OM", "MOMO", "KULU"].includes(paymentMethod)) {
      throw new Error("Méthode de paiement invalide. Utilisez: OM, MOMO ou KULU");
    }

    logStep("Input validated", { amount, paymentMethod, phone: payerPhone.substring(0, 6) + "...", useSandbox });

    // Initialize Supabase admin client
    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
      { auth: { persistSession: false } }
    );

    // Get authenticated user (optional - not required for sandbox testing)
    const authHeader = req.headers.get("Authorization");
    let userId: string | null = null;

    if (authHeader && authHeader.startsWith("Bearer ")) {
      const supabaseAnon = createClient(
        Deno.env.get("SUPABASE_URL") ?? "",
        Deno.env.get("SUPABASE_ANON_KEY") ?? ""
      );
      const token = authHeader.replace("Bearer ", "");
      const { data: userData } = await supabaseAnon.auth.getUser(token);
      if (userData.user) {
        userId = userData.user.id;
        logStep("User authenticated", { userId });
      }
    }

    // Check idempotency
    if (idempotencyKey) {
      const { data: existing } = await supabaseAdmin
        .from("djomy_transactions")
        .select("id, status, djomy_transaction_id, order_id")
        .eq("idempotency_key", idempotencyKey)
        .single();

      if (existing) {
        logStep("Idempotent request - returning existing", { existing });
        return new Response(
          JSON.stringify({
            success: true,
            transactionId: existing.id,
            djomyTransactionId: existing.djomy_transaction_id,
            orderId: existing.order_id,
            status: existing.status,
            message: "Transaction existante",
          }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 }
        );
      }
    }

    // Generate unique order ID
    const finalOrderId = orderId || `224SOL-${Date.now()}-${Math.random().toString(36).substring(2, 8).toUpperCase()}`;

    // Create transaction record (PENDING)
    const { data: newTransaction, error: insertError } = await supabaseAdmin
      .from("djomy_transactions")
      .insert({
        order_id: finalOrderId,
        user_id: userId,
        vendor_id: vendorId || null,
        amount,
        currency: "GNF",
        payment_method: paymentMethod,
        status: "PENDING",
        payer_phone: payerPhone.replace(/\s/g, ""),
        country_code: countryCode,
        description: description || `Paiement ${paymentMethod} - ${finalOrderId}`,
        idempotency_key: idempotencyKey || null,
        metadata: metadata,
        ip_address: req.headers.get("x-forwarded-for") || req.headers.get("cf-connecting-ip"),
        user_agent: req.headers.get("user-agent"),
      })
      .select()
      .single();

    if (insertError) {
      logStep("DB insert error", { error: insertError.message });
      throw new Error("Erreur lors de la création de la transaction");
    }

    logStep("Transaction created", { id: newTransaction.id, orderId: finalOrderId });

    // Initialize Djomy client (sandbox ou production selon le paramètre)
    const djomyClient = createDjomyClient(useSandbox);

    // Log API request
    await supabaseAdmin
      .from("djomy_api_logs")
      .insert({
        request_type: "INIT_PAYMENT",
        endpoint: "/v1/payments",
        request_payload: { amount, paymentMethod, countryCode },
        transaction_id: newTransaction.id,
      });

    // Format phone number (international format)
    const formattedPhone = payerPhone.replace(/\s/g, "").replace(/^\+/, "00");

    // Call Djomy API
    const djomyStartTime = Date.now();
    const djomyResult = await djomyClient.initiatePayment({
      paymentMethod: paymentMethod as 'OM' | 'MOMO' | 'KULU',
      payerIdentifier: formattedPhone,
      amount: amount,
      countryCode: countryCode,
      merchantPaymentReference: finalOrderId,
      description: description || `Paiement 224Solutions - ${finalOrderId}`,
      returnUrl: returnUrl,
      cancelUrl: cancelUrl,
      metadata: metadata,
    });
    const djomyDuration = Date.now() - djomyStartTime;

    logStep("Djomy API response", { 
      success: djomyResult.success, 
      duration: djomyDuration,
      transactionId: djomyResult.transactionId 
    });

    // Update API log
    await supabaseAdmin
      .from("djomy_api_logs")
      .update({
        response_status: djomyResult.success ? 200 : 400,
        response_payload: djomyResult.data,
        duration_ms: djomyDuration,
        error_message: djomyResult.error || null,
      })
      .eq("transaction_id", newTransaction.id);

    if (!djomyResult.success) {
      // Update transaction status to FAILED
      await supabaseAdmin
        .from("djomy_transactions")
        .update({
          status: "FAILED",
          error_message: djomyResult.error,
          updated_at: new Date().toISOString(),
        })
        .eq("id", newTransaction.id);

      throw new Error(djomyResult.error || "Erreur Djomy inconnue");
    }

    // Update transaction with Djomy response
    await supabaseAdmin
      .from("djomy_transactions")
      .update({
        status: "PROCESSING",
        djomy_transaction_id: djomyResult.transactionId,
        djomy_response: djomyResult.data,
        updated_at: new Date().toISOString(),
      })
      .eq("id", newTransaction.id);

    const totalDuration = Date.now() - startTime;
    logStep("✅ Payment init completed", { 
      transactionId: newTransaction.id, 
      djomyId: djomyResult.transactionId,
      totalDuration 
    });

    return new Response(
      JSON.stringify({
        success: true,
        transactionId: newTransaction.id,
        djomyTransactionId: djomyResult.transactionId,
        orderId: finalOrderId,
        status: "PROCESSING",
        redirectUrl: djomyResult.redirectUrl, // Pour KULU
        message: "Paiement initié - En attente de confirmation",
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 }
    );

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    const duration = Date.now() - startTime;
    
    // Categorize errors
    let errorCode = "UNKNOWN";
    let userFriendlyMessage = errorMessage;

    if (errorMessage.includes("403")) {
      errorCode = "DJOMY_AUTH_403";
      userFriendlyMessage = "🔴 Accès refusé par Djomy. Vérifiez que vos credentials sont autorisés.";
    } else if (errorMessage.includes("401")) {
      errorCode = "DJOMY_AUTH_401";
      userFriendlyMessage = "🔴 Authentification Djomy échouée. Vérifiez DJOMY_CLIENT_ID et DJOMY_CLIENT_SECRET.";
    } else if (errorMessage.includes("DJOMY_CLIENT_ID")) {
      errorCode = "MISSING_CREDENTIALS";
    } else if (errorMessage.includes("Format Client ID")) {
      errorCode = "INVALID_CLIENT_ID";
    }
    
    logStep("❌ ERROR", { code: errorCode, message: errorMessage, duration });

    return new Response(
      JSON.stringify({ 
        success: false, 
        error: userFriendlyMessage,
        errorCode: errorCode,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 }
    );
  }
});
