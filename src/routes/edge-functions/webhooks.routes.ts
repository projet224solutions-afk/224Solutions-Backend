import { Router, Request, Response } from "express";
import { createClient } from "@supabase/supabase-js";
import Stripe from "stripe";

const router = Router();

const supabaseAdmin = createClient(
  process.env.SUPABASE_URL || "",
  process.env.SUPABASE_SERVICE_ROLE_KEY || "",
  {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
  }
);

const stripe = process.env.STRIPE_SECRET_KEY
  ? new Stripe(process.env.STRIPE_SECRET_KEY, {
      apiVersion: "2026-03-25.dahlia",
    })
  : null;

function safeJsonParse(value: string): any {
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

router.post("/stripe", async (req: Request, res: Response) => {
  try {
    if (!stripe) {
      return res.status(503).json({ success: false, error: "Stripe not configured" });
    }

    const signature = req.headers["stripe-signature"] as string | undefined;
    const webhookSecret = process.env.STRIPE_WEBHOOK_SECRET || "";

    if (!signature || !webhookSecret) {
      return res.status(400).json({ success: false, error: "Missing stripe signature or webhook secret" });
    }

    const rawBody = Buffer.isBuffer(req.body)
      ? req.body.toString("utf8")
      : typeof req.body === "string"
        ? req.body
        : JSON.stringify(req.body || {});

    let event: Stripe.Event;
    try {
      event = stripe.webhooks.constructEvent(rawBody, signature, webhookSecret);
    } catch (err) {
      return res.status(400).json({ success: false, error: "Invalid stripe signature" });
    }

    // Guard idempotence : ignorer les événements déjà traités
    // (évite la double exécution si les deux endpoints sont configurés dans Stripe)
    const { data: existingEvent } = await supabaseAdmin
      .from("webhook_events")
      .select("processing_status")
      .eq("provider", "stripe")
      .eq("webhook_id", event.id)
      .maybeSingle();

    if (existingEvent?.processing_status === "completed") {
      return res.status(200).json({ success: true, received: true, status: "already_processed" });
    }

    if (event.type === "payment_intent.succeeded") {
      const paymentIntent = event.data.object as Stripe.PaymentIntent;
      const orderId = paymentIntent.metadata?.order_id;

      if (orderId) {
        await supabaseAdmin
          .from("orders")
          .update({
            payment_status: "paid",
            status: "confirmed",
            updated_at: new Date().toISOString(),
          })
          .eq("id", orderId);
      }

      await supabaseAdmin
        .from("stripe_payments")
        .update({ status: "succeeded", updated_at: new Date().toISOString() })
        .eq("payment_intent_id", paymentIntent.id);
    }

    if (event.type === "payment_intent.payment_failed") {
      const paymentIntent = event.data.object as Stripe.PaymentIntent;
      const orderId = paymentIntent.metadata?.order_id;

      if (orderId) {
        await supabaseAdmin
          .from("orders")
          .update({ payment_status: "failed", updated_at: new Date().toISOString() })
          .eq("id", orderId);
      }

      await supabaseAdmin
        .from("stripe_payments")
        .update({
          status: "failed",
          failure_reason: paymentIntent.last_payment_error?.message || null,
          updated_at: new Date().toISOString(),
        })
        .eq("payment_intent_id", paymentIntent.id);
    }

    await supabaseAdmin.from("webhook_events").upsert(
      {
        provider: "stripe",
        webhook_id: event.id,
        event_type: event.type,
        payload: event as any,
        processing_status: "completed",
        processed_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      },
      { onConflict: "provider,webhook_id" }
    );

    return res.status(200).json({ success: true, received: true, type: event.type });
  } catch (error) {
    return res.status(500).json({ success: false, error: error instanceof Error ? error.message : "Internal error" });
  }
});

router.post("/paypal", async (req: Request, res: Response) => {
  try {
    const payload = req.body || {};
    const eventType = payload.event_type;
    const resource = payload.resource || {};

    if (eventType === "CHECKOUT.ORDER.COMPLETED") {
      const orderId = resource?.metadata?.order_id || resource?.custom_id;
      if (orderId) {
        await supabaseAdmin
          .from("orders")
          .update({
            payment_status: "paid",
            status: "confirmed",
            updated_at: new Date().toISOString(),
          })
          .eq("id", orderId);
      }
    }

    await supabaseAdmin.from("webhook_events").insert({
      provider: "paypal",
      webhook_id: resource?.id || `paypal-${Date.now()}`,
      event_type: eventType || "unknown",
      payload: payload as any,
      processing_status: "completed",
      processed_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    });

    return res.status(200).json({ success: true, received: true });
  } catch (error) {
    return res.status(500).json({ success: false, error: error instanceof Error ? error.message : "Internal error" });
  }
});

router.post("/chapchappay", async (req: Request, res: Response) => {
  try {
    const payload = req.body || {};
    const txRef = payload?.reference || payload?.tx_ref || payload?.transaction_id || `chap-${Date.now()}`;
    const status = (payload?.status || "").toLowerCase();

    if (["success", "succeeded", "completed", "paid"].includes(status)) {
      const orderId = payload?.metadata?.order_id || payload?.order_id;
      if (orderId) {
        await supabaseAdmin
          .from("orders")
          .update({ payment_status: "paid", status: "confirmed", updated_at: new Date().toISOString() })
          .eq("id", orderId);
      }
    }

    await supabaseAdmin.from("webhook_events").insert({
      provider: "chapchappay",
      webhook_id: String(txRef),
      event_type: payload?.event || "payment.update",
      payload: payload as any,
      processing_status: "completed",
      processed_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    });

    return res.status(200).json({ success: true, received: true });
  } catch (error) {
    return res.status(500).json({ success: false, error: error instanceof Error ? error.message : "Internal error" });
  }
});

router.post("/subscription", async (req: Request, res: Response) => {
  try {
    const payload = req.body || {};
    const provider = String(payload?.provider || "subscription");
    const webhookId = payload?.id || payload?.event_id || `${provider}-${Date.now()}`;

    await supabaseAdmin.from("webhook_events").insert({
      provider,
      webhook_id: String(webhookId),
      event_type: payload?.event || payload?.type || "subscription.update",
      payload: payload as any,
      processing_status: "completed",
      processed_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    });

    return res.status(200).json({ success: true, received: true });
  } catch (error) {
    return res.status(500).json({ success: false, error: error instanceof Error ? error.message : "Internal error" });
  }
});

router.post("/replay", async (req: Request, res: Response) => {
  try {
    const { provider, webhook_id } = req.body || {};
    if (!provider || !webhook_id) {
      return res.status(400).json({ success: false, error: "provider and webhook_id are required" });
    }

    const { data: event, error } = await supabaseAdmin
      .from("webhook_events")
      .select("*")
      .eq("provider", provider)
      .eq("webhook_id", webhook_id)
      .maybeSingle();

    if (error || !event) {
      return res.status(404).json({ success: false, error: "Webhook event not found" });
    }

    // Replay marker only; business replay should be done per provider handler.
    await supabaseAdmin
      .from("webhook_events")
      .update({
        processing_status: "processing",
        updated_at: new Date().toISOString(),
      })
      .eq("id", event.id);

    return res.status(200).json({
      success: true,
      message: "Webhook marked for replay",
      event_id: event.id,
    });
  } catch (error) {
    return res.status(500).json({ success: false, error: error instanceof Error ? error.message : "Internal error" });
  }
});

export default router;
