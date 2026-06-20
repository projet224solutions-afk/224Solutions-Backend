/**
 * 💳 CHAPCHAPPAY PULL - Débit Mobile Money Client
 * Edge Function pour débiter un compte Orange Money / MTN MoMo
 * 224SOLUTIONS
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.2";
import { createChapChapPayClient } from "../_shared/chapchappay-client.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const logStep = (step: string, details?: Record<string, unknown>) => {
  const timestamp = new Date().toISOString();
  const detailsStr = details ? ` - ${JSON.stringify(details)}` : "";
  console.log(`[${timestamp}] [CCP-PULL] ${step}${detailsStr}`);
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  const startTime = Date.now();
  
  try {
    logStep("PULL payment started");

    const body = await req.json();
    const {
      amount,
      currency = "GNF",
      paymentMethod, // orange_money, mtn_momo, paycard
      customerPhone,
      customerName,
      description,
      orderId,
      useSandbox = false,
      metadata = {},
    } = body;

    logStep("Request received", { amount, paymentMethod, useSandbox });

    // Validation
    if (!amount || amount <= 0) {
      throw new Error("Montant invalide - doit être supérieur à 0");
    }
    if (!customerPhone || customerPhone.length < 8) {
      throw new Error("Numéro de téléphone invalide - minimum 8 chiffres");
    }
    if (!paymentMethod || !["orange_money", "mtn_momo", "paycard", "card"].includes(paymentMethod)) {
      throw new Error("Méthode de paiement invalide. Utilisez: orange_money, mtn_momo, paycard ou card");
    }

    logStep("Input validated", { 
      amount, 
      paymentMethod, 
      phone: customerPhone.substring(0, 6) + "..." 
    });

    // Initialize Supabase admin client
    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
      { auth: { persistSession: false } }
    );

    // Get authenticated user (optional)
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

    // Generate unique order ID
    const finalOrderId = orderId || `CCP-PULL-${Date.now()}-${Math.random().toString(36).substring(2, 8).toUpperCase()}`;

    // Create transaction record (PENDING)
    const { data: newTransaction, error: insertError } = await supabaseAdmin
      .from("mobile_money_transactions")
      .insert({
        order_id: finalOrderId,
        user_id: userId,
        amount,
        currency,
        payment_method: paymentMethod,
        payment_type: "pull",
        status: "pending",
        customer_phone: customerPhone.replace(/\s/g, ""),
        customer_name: customerName,
        description: description || `Paiement ChapChapPay - ${finalOrderId}`,
        provider: "chapchappay",
        metadata: metadata,
        ip_address: req.headers.get("x-forwarded-for") || req.headers.get("cf-connecting-ip"),
      })
      .select()
      .single();

    if (insertError) {
      logStep("DB insert error", { error: insertError.message });
      // Continue anyway - don't fail payment due to logging
    } else {
      logStep("Transaction created", { id: newTransaction?.id, orderId: finalOrderId });
    }

    // Initialize ChapChapPay client
    const ccpClient = createChapChapPayClient(useSandbox);

    // Get webhook URL
    const webhookUrl = `${Deno.env.get("SUPABASE_URL")}/functions/v1/chapchappay-webhook`;

    // Call ChapChapPay API
    const ccpStartTime = Date.now();
    const ccpResult = await ccpClient.initiatePullPayment({
      amount,
      currency,
      paymentMethod: paymentMethod as 'orange_money' | 'mtn_momo' | 'paycard' | 'wave' | 'card',
      customerPhone,
      customerName,
      description: description || `Paiement 224Solutions - ${finalOrderId}`,
      orderId: finalOrderId,
      webhookUrl,
      metadata,
    });
    const ccpDuration = Date.now() - ccpStartTime;

    logStep("ChapChapPay API response", { 
      success: ccpResult.success, 
      duration: ccpDuration,
      transactionId: ccpResult.transactionId 
    });

    if (!ccpResult.success) {
      // Update transaction status to FAILED
      if (newTransaction?.id) {
        await supabaseAdmin
          .from("mobile_money_transactions")
          .update({
            status: "failed",
            error_message: ccpResult.error,
            updated_at: new Date().toISOString(),
          })
          .eq("id", newTransaction.id);
      }

      throw new Error(ccpResult.error || "Erreur ChapChapPay inconnue");
    }

    // Update transaction with ChapChapPay response
    if (newTransaction?.id) {
      await supabaseAdmin
        .from("mobile_money_transactions")
        .update({
          status: "processing",
          provider_transaction_id: ccpResult.transactionId,
          provider_response: ccpResult.data,
          requires_otp: ccpResult.requiresOtp || false,
          updated_at: new Date().toISOString(),
        })
        .eq("id", newTransaction.id);
    }

    const totalDuration = Date.now() - startTime;
    logStep("✅ PULL payment initiated", { 
      transactionId: newTransaction?.id, 
      ccpId: ccpResult.transactionId,
      totalDuration 
    });

    return new Response(
      JSON.stringify({
        success: true,
        transactionId: newTransaction?.id || ccpResult.transactionId,
        ccpTransactionId: ccpResult.transactionId,
        orderId: finalOrderId,
        status: "processing",
        requiresOtp: ccpResult.requiresOtp || false,
        message: ccpResult.requiresOtp 
          ? "Code OTP envoyé sur votre téléphone" 
          : "Paiement initié - Confirmez sur votre téléphone",
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 }
    );

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    const duration = Date.now() - startTime;
    
    logStep("❌ ERROR", { message: errorMessage, duration });

    return new Response(
      JSON.stringify({ 
        success: false, 
        error: errorMessage,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 }
    );
  }
});
