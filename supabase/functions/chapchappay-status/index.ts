/**
 * 🔍 CHAPCHAPPAY STATUS - Vérifier le statut d'une transaction
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
  console.log(`[${timestamp}] [CCP-STATUS] ${step}${detailsStr}`);
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    logStep("Status check started");

    const body = await req.json();
    const { transactionId, orderId, useSandbox = false } = body;

    if (!transactionId && !orderId) {
      throw new Error("transactionId ou orderId requis");
    }

    logStep("Checking status", { transactionId, orderId, useSandbox });

    // Initialize ChapChapPay client
    const ccpClient = createChapChapPayClient(useSandbox);

    // Call ChapChapPay Status API
    const statusResult = await ccpClient.checkStatus(transactionId, orderId);

    logStep("Status result", { 
      success: statusResult.success, 
      status: statusResult.status 
    });

    if (!statusResult.success) {
      throw new Error(statusResult.error || "Impossible de vérifier le statut");
    }

    // Update local database if status changed
    if (statusResult.transactionId && statusResult.status) {
      const supabaseAdmin = createClient(
        Deno.env.get("SUPABASE_URL") ?? "",
        Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
        { auth: { persistSession: false } }
      );

      // Try to update mobile_money_transactions
      await supabaseAdmin
        .from("mobile_money_transactions")
        .update({
          status: statusResult.status,
          paid_amount: statusResult.paidAmount,
          fees: statusResult.fees,
          completed_at: statusResult.completedAt,
          updated_at: new Date().toISOString(),
        })
        .or(`provider_transaction_id.eq.${statusResult.transactionId},order_id.eq.${orderId}`);

      logStep("Local DB updated");
    }

    return new Response(
      JSON.stringify({
        success: true,
        transactionId: statusResult.transactionId,
        status: statusResult.status,
        amount: statusResult.amount,
        paidAmount: statusResult.paidAmount,
        fees: statusResult.fees,
        paymentMethod: statusResult.paymentMethod,
        customerPhone: statusResult.customerPhone,
        createdAt: statusResult.createdAt,
        completedAt: statusResult.completedAt,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 }
    );

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    logStep("❌ ERROR", { message: errorMessage });

    return new Response(
      JSON.stringify({ success: false, error: errorMessage }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 }
    );
  }
});
