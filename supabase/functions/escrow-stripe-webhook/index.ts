import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@18";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, stripe-signature",
};

const logStep = (step: string, details?: any) => {
  const detailsStr = details ? ` - ${JSON.stringify(details)}` : '';
  console.log(`[STRIPE-WEBHOOK] ${step}${detailsStr}`);
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    logStep("🔔 Webhook received");

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    );

    const stripeKey = Deno.env.get("STRIPE_SECRET_KEY");
    if (!stripeKey) {
      throw new Error("Stripe key not configured");
    }

    const stripe = new Stripe(stripeKey, { apiVersion: "2025-08-27.basil" });

    // Verify webhook signature
    const signature = req.headers.get("stripe-signature");
    const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
    
    let event: Stripe.Event;

    if (webhookSecret && signature) {
      const body = await req.text();
      try {
        event = stripe.webhooks.constructEvent(body, signature, webhookSecret);
        logStep("✅ Webhook signature verified");
      } catch (err) {
        logStep("❌ Webhook signature verification failed", err);
        const errorMessage = err instanceof Error ? err.message : 'Signature verification failed';
        return new Response(
          JSON.stringify({ error: `Webhook Error: ${errorMessage}` }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
    } else {
      // If no webhook secret, parse the body directly (not recommended for production)
      event = await req.json();
      logStep("⚠️ Processing webhook without signature verification");
    }

    const eventType = event.type;
    const obj = event.data.object;

    logStep(`📋 Event type: ${eventType}`);

    // Handle payment_intent events
    if (eventType === 'payment_intent.succeeded') {
      const pi = obj as Stripe.PaymentIntent;
      logStep(`💰 PaymentIntent succeeded: ${pi.id}`, { status: pi.status });

      // Find escrow by PaymentIntent ID
      const { data: escrows, error: fetchError } = await supabase
        .from("escrow_transactions")
        .select("*")
        .eq("stripe_payment_intent_id", pi.id);

      if (fetchError || !escrows || escrows.length === 0) {
        logStep("⚠️ No escrow found for PaymentIntent");
        return new Response(JSON.stringify({ received: true }), {
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const escrow = escrows[0];
      const newStatus = pi.status === 'requires_capture' ? 'held' : (pi.status === 'succeeded' ? 'released' : escrow.status);

      logStep(`🔄 Updating escrow status: ${escrow.status} -> ${newStatus}`);

      await supabase
        .from("escrow_transactions")
        .update({
          status: newStatus,
          metadata: {
            ...escrow.metadata,
            stripe_status: pi.status,
            updated_via_webhook: true,
            last_webhook_event: eventType,
            last_webhook_at: new Date().toISOString(),
          },
        })
        .eq("id", escrow.id);

      // Log the action
      await supabase.from("escrow_action_logs").insert({
        escrow_id: escrow.id,
        action_type: 'webhook_update',
        performed_by: null,
        notes: `Stripe webhook: ${eventType}`,
        metadata: {
          event_type: eventType,
          stripe_payment_intent_id: pi.id,
          stripe_status: pi.status,
        },
      });

    } else if (eventType === 'payment_intent.payment_failed') {
      const pi = obj as Stripe.PaymentIntent;
      logStep(`❌ PaymentIntent failed: ${pi.id}`);

      const { data: escrows } = await supabase
        .from("escrow_transactions")
        .select("*")
        .eq("stripe_payment_intent_id", pi.id);

      if (escrows && escrows.length > 0) {
        const escrow = escrows[0];
        await supabase
          .from("escrow_transactions")
          .update({
            status: 'failed',
            metadata: {
              ...escrow.metadata,
              failure_reason: pi.last_payment_error?.message || 'Payment failed',
              updated_via_webhook: true,
            },
          })
          .eq("id", escrow.id);

        // Send notification to buyer
        await supabase.from("communication_notifications").insert({
          user_id: escrow.payer_id,
          type: "escrow_failed",
          title: "Paiement échoué",
          body: `Le paiement de ${escrow.amount} ${escrow.currency} a échoué. Veuillez réessayer.`,
          metadata: { escrow_id: escrow.id },
        });
      }

    } else if (eventType === 'payment_intent.canceled') {
      const pi = obj as Stripe.PaymentIntent;
      logStep(`🚫 PaymentIntent canceled: ${pi.id}`);

      const { data: escrows } = await supabase
        .from("escrow_transactions")
        .select("*")
        .eq("stripe_payment_intent_id", pi.id);

      if (escrows && escrows.length > 0) {
        const escrow = escrows[0];
        await supabase
          .from("escrow_transactions")
          .update({
            status: 'refunded',
            refunded_at: new Date().toISOString(),
            metadata: {
              ...escrow.metadata,
              canceled_via_webhook: true,
            },
          })
          .eq("id", escrow.id);

        await supabase.from("escrow_action_logs").insert({
          escrow_id: escrow.id,
          action_type: 'canceled',
          performed_by: null,
          notes: `PaymentIntent canceled via Stripe`,
        });
      }

    } else if (eventType === 'charge.refunded' || eventType === 'charge.refund.updated') {
      const charge = obj as Stripe.Charge;
      const piId = charge.payment_intent as string;
      
      if (piId) {
        logStep(`💸 Charge refunded: ${charge.id}`);

        const { data: escrows } = await supabase
          .from("escrow_transactions")
          .select("*")
          .eq("stripe_payment_intent_id", piId);

        if (escrows && escrows.length > 0) {
          const escrow = escrows[0];
          await supabase
            .from("escrow_transactions")
            .update({
              status: 'refunded',
              refunded_at: new Date().toISOString(),
              metadata: {
                ...escrow.metadata,
                refund_amount: charge.amount_refunded,
                refunded_via_webhook: true,
              },
            })
            .eq("id", escrow.id);

          await supabase.from("escrow_action_logs").insert({
            escrow_id: escrow.id,
            action_type: 'refunded',
            performed_by: null,
            notes: `Charge refunded via Stripe webhook`,
            metadata: {
              charge_id: charge.id,
              refund_amount: charge.amount_refunded,
            },
          });
        }
      }
    }

    logStep(`✅ Webhook processed successfully`);

    return new Response(
      JSON.stringify({ received: true, event_type: eventType }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error) {
    logStep("❌ Webhook processing error", error);
    return new Response(
      JSON.stringify({
        error: error instanceof Error ? error.message : "Unknown error",
      }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
