/**
 * 🔔 DJOMY WEBHOOK - VERSION CONFORME À LA DOC OFFICIELLE
 * https://developers.djomy.africa/#tag/Webhooks
 * 
 * Gère les notifications de changement de statut des paiements
 * Événements: payment.created, payment.pending, payment.success, payment.failed, payment.cancelled
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.2";
import { verifyWebhookSignature } from "../_shared/djomy-client.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-webhook-signature",
};

const logStep = (step: string, details?: Record<string, unknown>) => {
  const timestamp = new Date().toISOString();
  const detailsStr = details ? ` - ${JSON.stringify(details)}` : "";
  console.log(`[${timestamp}] [DJOMY-WEBHOOK] ${step}${detailsStr}`);
};

// Map Djomy event types to internal status
const statusMap: Record<string, string> = {
  "payment.created": "CREATED",
  "payment.redirected": "REDIRECTED",
  "payment.pending": "PENDING",
  "payment.success": "SUCCESS",
  "payment.failed": "FAILED",
  "payment.cancelled": "CANCELLED",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    logStep("Webhook received");

    // Get client secret for signature verification
    const clientSecret = Deno.env.get("DJOMY_CLIENT_SECRET");
    if (!clientSecret) {
      logStep("⚠️ DJOMY_CLIENT_SECRET not configured");
    }

    // Get signature from header (format: v1:signature)
    const webhookSignature = req.headers.get("X-Webhook-Signature");
    logStep("Signature header", { hasSignature: !!webhookSignature });

    // Get raw body for signature verification
    const rawBody = await req.text();
    logStep("Payload received", { bodyLength: rawBody.length });

    // Verify signature if both are present
    if (webhookSignature && clientSecret) {
      const isValid = await verifyWebhookSignature(rawBody, webhookSignature, clientSecret);
      if (!isValid) {
        logStep("❌ Invalid webhook signature - rejecting");
        return new Response(
          JSON.stringify({ error: "Invalid signature" }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 401 }
        );
      }
      logStep("✅ Signature verified");
    }

    // Parse the webhook payload
    const payload = JSON.parse(rawBody);
    
    const {
      eventType,
      eventId,
      data,
      paymentLinkReference,
      timestamp,
      message,
      metadata,
    } = payload;

    logStep("Webhook payload", {
      eventType,
      eventId,
      transactionId: data?.transactionId,
      status: data?.status,
      paidAmount: data?.paidAmount,
    });

    // Initialize Supabase admin client
    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
      { auth: { persistSession: false } }
    );

    const internalStatus = statusMap[eventType] || "UNKNOWN";
    logStep("Status mapped", { eventType, internalStatus });

    // Find and update the transaction
    if (data?.transactionId) {
      // First try to find by djomy_transaction_id
      let { data: transaction, error: findError } = await supabaseAdmin
        .from("djomy_transactions")
        .select("id, user_id, vendor_id, order_id, amount, status")
        .eq("djomy_transaction_id", data.transactionId)
        .single();

      // If not found, try by merchantPaymentReference (order_id)
      if (!transaction && data.merchantPaymentReference) {
        const result = await supabaseAdmin
          .from("djomy_transactions")
          .select("id, user_id, vendor_id, order_id, amount, status")
          .eq("order_id", data.merchantPaymentReference)
          .single();
        transaction = result.data;
      }

      if (transaction) {
        // Update transaction status
        const { error: updateError } = await supabaseAdmin
          .from("djomy_transactions")
          .update({
            status: internalStatus,
            djomy_transaction_id: data.transactionId,
            paid_amount: data.paidAmount,
            received_amount: data.receivedAmount,
            fees: data.fees,
            webhook_event_id: eventId,
            webhook_received_at: new Date().toISOString(),
            djomy_response: payload,
            updated_at: new Date().toISOString(),
          })
          .eq("id", transaction.id);

        if (updateError) {
          logStep("Update error", { error: updateError.message });
        } else {
          logStep("✅ Transaction updated", { id: transaction.id, newStatus: internalStatus });
        }

        // Handle successful payment
        if (eventType === "payment.success" && data.paidAmount) {
          await handleSuccessfulPayment(supabaseAdmin, transaction, data, metadata);
        }

        // Handle failed/cancelled payment
        if (eventType === "payment.failed" || eventType === "payment.cancelled") {
          await handleFailedPayment(supabaseAdmin, transaction, data);
        }
      } else {
        logStep("⚠️ Transaction not found", { djomyId: data.transactionId });
      }
    }

    // Also update djomy_payments if exists
    if (data?.transactionId) {
      await supabaseAdmin
        .from("djomy_payments")
        .update({
          status: internalStatus.toLowerCase(),
          paid_amount: data.paidAmount,
          received_amount: data.receivedAmount,
          fees: data.fees,
          webhook_event_id: eventId,
          webhook_received_at: new Date().toISOString(),
          response_data: payload,
          updated_at: new Date().toISOString(),
        })
        .eq("transaction_id", data.transactionId);
    }

    // Log webhook event
    await supabaseAdmin
      .from("djomy_webhook_logs")
      .insert({
        event_id: eventId,
        event_type: eventType,
        transaction_id: data?.transactionId,
        payload: payload,
        processed_at: new Date().toISOString(),
      });

    logStep("✅ Webhook processed successfully");

    return new Response(
      JSON.stringify({ success: true, message: "Webhook processed" }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 }
    );

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    logStep("❌ ERROR processing webhook", { message: errorMessage });
    
    // Return 200 to prevent Djomy from retrying (webhook was received)
    return new Response(
      JSON.stringify({ success: false, error: errorMessage }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 }
    );
  }
});

/**
 * Handle successful payment - credit wallet, update order, etc.
 */
async function handleSuccessfulPayment(
  supabase: any,
  transaction: { id: string; user_id: string | null; vendor_id: string | null; order_id: string | null; amount: number },
  data: { paidAmount: number; receivedAmount?: number; paymentMethod?: string; payerIdentifier?: string; fees?: number },
  metadata?: Record<string, unknown>
) {
  logStep("💰 Processing successful payment", { 
    transactionId: transaction.id,
    amount: data.paidAmount 
  });

  // Credit user wallet if user_id exists
  if (transaction.user_id) {
    const { data: wallet } = await supabase
      .from("wallets")
      .select("id, balance")
      .eq("user_id", transaction.user_id)
      .single();

    if (wallet) {
      await supabase.from("wallet_transactions").insert({
        wallet_id: wallet.id,
        user_id: transaction.user_id,
        type: "deposit",
        amount: data.receivedAmount || data.paidAmount,
        description: `Recharge via ${data.paymentMethod || "Mobile Money"}`,
        status: "completed",
        reference: transaction.id,
      });
      logStep("✅ Wallet credited", { userId: transaction.user_id });
    }
  }

  // Update order status if order_id exists
  if (transaction.order_id) {
    await supabase
      .from("orders")
      .update({ payment_status: "paid", updated_at: new Date().toISOString() })
      .eq("id", transaction.order_id);
    logStep("✅ Order updated to paid", { orderId: transaction.order_id });
  }
}

/**
 * Handle failed/cancelled payment
 */
async function handleFailedPayment(
  supabase: any,
  transaction: { id: string; order_id: string | null },
  data: { status?: string }
) {
  logStep("❌ Processing failed payment", { transactionId: transaction.id });

  if (transaction.order_id) {
    await supabase
      .from("orders")
      .update({ payment_status: "failed", updated_at: new Date().toISOString() })
      .eq("id", transaction.order_id);
  }
}
