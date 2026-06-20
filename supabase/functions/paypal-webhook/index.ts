import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { verifyPayPalWebhook } from "../_shared/hmac-guard.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, paypal-transmission-id, paypal-transmission-time, paypal-transmission-sig, paypal-cert-url, paypal-auth-algo",
};

const log = (step: string, details?: unknown) => {
  console.log(`[PAYPAL-WEBHOOK] ${step}${details ? ` - ${JSON.stringify(details)}` : ""}`);
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
  );

  const rawBody = await req.text();
  let event: any;

  try {
    event = JSON.parse(rawBody);
  } catch {
    log("❌ Invalid JSON body");
    return new Response(JSON.stringify({ error: "Invalid JSON" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const eventId = event.id || "unknown";
  const eventType = event.event_type || "unknown";
  const transmissionId = req.headers.get("paypal-transmission-id");

  log(`🔔 Received: ${eventType}`, { eventId });

  // Store raw event immediately
  await supabase.from("paypal_webhook_events").upsert({
    event_id: eventId,
    event_type: eventType,
    resource_type: event.resource_type,
    resource_id: event.resource?.id,
    summary: event.summary,
    paypal_order_id: event.resource?.supplementary_data?.related_ids?.order_id || event.resource?.id,
    transmission_id: transmissionId,
    transmission_time: req.headers.get("paypal-transmission-time"),
    processing_status: "received",
    raw_payload: event,
    signature_verified: false,
  }, { onConflict: "event_id" });

  // ── Verify signature ──
  const webhookId = Deno.env.get("PAYPAL_WEBHOOK_ID");
  if (!webhookId) {
    log("⚠️ PAYPAL_WEBHOOK_ID not configured, skipping verification");
    await supabase.from("paypal_webhook_events")
      .update({ processing_status: "failed", processing_error: "PAYPAL_WEBHOOK_ID not configured" })
      .eq("event_id", eventId);
    return new Response(JSON.stringify({ received: true, warning: "webhook_id_missing" }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const verification = await verifyPayPalWebhook(req, rawBody, webhookId);

  if (!verification.valid) {
    log(`❌ Signature invalid: ${verification.error}`);
    await supabase.from("paypal_webhook_events")
      .update({ processing_status: "failed", processing_error: verification.error })
      .eq("event_id", eventId);
    return new Response(JSON.stringify({ error: "Invalid signature" }), {
      status: 401,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  log("✅ Signature verified");
  await supabase.from("paypal_webhook_events")
    .update({ signature_verified: true, processing_status: "verified" })
    .eq("event_id", eventId);

  // ── Process event ──
  try {
    const resource = event.resource || {};

    switch (eventType) {
      case "PAYMENT.CAPTURE.COMPLETED": {
        const captureId = resource.id;
        const orderId = resource.supplementary_data?.related_ids?.order_id;
        const amount = parseFloat(resource.amount?.value || "0");
        const currency = resource.amount?.currency_code || "USD";

        log(`💰 Capture completed: ${captureId}`, { orderId, amount, currency });

        // Find related order in our system
        if (orderId) {
          // Update any pending order
          const { data: orders } = await supabase
            .from("orders")
            .select("id, user_id, total_amount, status")
            .eq("payment_intent_id", orderId)
            .eq("status", "pending");

          if (orders && orders.length > 0) {
            const order = orders[0];
            await supabase.from("orders")
              .update({ status: "confirmed", payment_status: "paid" })
              .eq("id", order.id);

            log(`📦 Order ${order.id} confirmed`);
          }

          // Check for wallet deposit
          const { data: deposits } = await supabase
            .from("wallet_transactions")
            .select("id, user_id, amount, status")
            .eq("reference", orderId)
            .eq("status", "pending");

          if (deposits && deposits.length > 0) {
            const deposit = deposits[0];
            // Credit wallet
            await supabase.rpc("process_wallet_transaction", {
              p_sender_id: null,
              p_receiver_id: deposit.user_id,
              p_amount: deposit.amount,
              p_currency: "GNF",
              p_description: `Dépôt PayPal (${amount} ${currency})`,
            });

            await supabase.from("wallet_transactions")
              .update({ status: "completed" })
              .eq("id", deposit.id);

            log(`💳 Wallet credited for user ${deposit.user_id}`);
          }
        }
        break;
      }

      case "PAYMENT.CAPTURE.DENIED":
      case "PAYMENT.CAPTURE.REFUNDED": {
        const orderId = resource.supplementary_data?.related_ids?.order_id;
        const status = eventType === "PAYMENT.CAPTURE.DENIED" ? "failed" : "refunded";

        log(`⚠️ Capture ${status}: ${resource.id}`);

        if (orderId) {
          await supabase.from("orders")
            .update({ status, payment_status: status })
            .eq("payment_intent_id", orderId);
        }
        break;
      }

      case "CHECKOUT.ORDER.APPROVED": {
        log(`✅ Order approved: ${resource.id}`);
        // Order approved, capture will follow
        break;
      }

      default:
        log(`ℹ️ Unhandled event type: ${eventType}`);
    }

    await supabase.from("paypal_webhook_events")
      .update({ processing_status: "processed", processed_at: new Date().toISOString() })
      .eq("event_id", eventId);

  } catch (err) {
    const errMsg = err instanceof Error ? err.message : "Processing error";
    log(`❌ Processing error: ${errMsg}`);
    await supabase.from("paypal_webhook_events")
      .update({ processing_status: "failed", processing_error: errMsg })
      .eq("event_id", eventId);
  }

  return new Response(JSON.stringify({ received: true, event_type: eventType }), {
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
});
