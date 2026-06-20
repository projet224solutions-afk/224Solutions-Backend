import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@18";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const logStep = (step: string, details?: any) => {
  const detailsStr = details ? ` - ${JSON.stringify(details)}` : '';
  console.log(`[ESCROW-CREATE-STRIPE] ${step}${detailsStr}`);
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    logStep("🔐 Starting Stripe escrow creation");

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    );

    // Verify user authentication
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(
        JSON.stringify({ success: false, error: "Unauthorized" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data: { user }, error: authError } = await supabase.auth.getUser(
      authHeader.replace("Bearer ", "")
    );

    if (authError || !user) {
      return new Response(
        JSON.stringify({ success: false, error: "Unauthorized" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Get request body
    const { buyer_id, seller_id, order_id, amount, currency = "GNF", payment_method_id } = await req.json();

    // Validate input
    if (!buyer_id || !seller_id || !amount) {
      logStep("❌ Missing required fields");
      return new Response(
        JSON.stringify({ success: false, error: "buyer_id, seller_id, and amount are required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (amount <= 0) {
      logStep("❌ Invalid amount");
      return new Response(
        JSON.stringify({ success: false, error: "Amount must be greater than 0" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    logStep(`📝 Creating Stripe escrow: ${buyer_id} -> ${seller_id}, ${amount} ${currency}`);

    // Initialize Stripe
    const stripeKey = Deno.env.get("STRIPE_SECRET_KEY");
    if (!stripeKey) {
      logStep("❌ Stripe key not configured");
      return new Response(
        JSON.stringify({ success: false, error: "Stripe not configured" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const stripe = new Stripe(stripeKey, { apiVersion: "2025-08-27.basil" });

    // Convert amount to smallest currency unit
    const zeroDecimalCurrencies = ['BIF','CLP','DJF','GNF','JPY','KMF','KRW','MGA','PYG','RWF','VUV','XAF','XOF','XPF'];
    const stripeAmount = Math.round(parseFloat(amount.toString()) * (zeroDecimalCurrencies.includes(currency.toUpperCase()) ? 1 : 100));

    logStep(`💰 Stripe amount: ${stripeAmount} ${currency}`);

    // Create PaymentIntent with manual capture to hold funds
    const piParams: any = {
      amount: stripeAmount,
      currency: currency.toLowerCase(),
      capture_method: 'manual',
      metadata: { buyer_id, seller_id, order_id: order_id || 'none', platform: '224SOLUTIONS' },
      description: `Escrow for order ${order_id || 'direct'}`,
    };

    if (payment_method_id) {
      piParams.payment_method = payment_method_id;
      piParams.confirm = true;
    }

    logStep("🔄 Creating Stripe PaymentIntent");
    const paymentIntent = await stripe.paymentIntents.create(piParams);
    logStep(`✅ PaymentIntent created: ${paymentIntent.id}`, { status: paymentIntent.status });

    // Create escrow record in database
    const { data: escrow, error: insertError } = await supabase
      .from("escrow_transactions")
      .insert({
        buyer_id,
        seller_id,
        order_id: order_id || null,
        amount,
        currency,
        status: paymentIntent.status === 'requires_capture' ? 'held' : 'pending',
        stripe_payment_intent_id: paymentIntent.id,
        metadata: {
          created_via: 'stripe_edge_function',
          timestamp: new Date().toISOString(),
          stripe_status: paymentIntent.status,
        },
      })
      .select()
      .single();

    if (insertError) {
      logStep("❌ Error creating escrow record", insertError);
      // Cancel the PaymentIntent if database insert fails
      await stripe.paymentIntents.cancel(paymentIntent.id);
      throw insertError;
    }

    logStep(`✅ Escrow record created: ${escrow.id}`);

    // Log the action
    await supabase.from("escrow_action_logs").insert({
      escrow_id: escrow.id,
      action_type: 'created',
      performed_by: user.id,
      notes: `Escrow created with Stripe PaymentIntent ${paymentIntent.id}`,
      metadata: {
        stripe_payment_intent_id: paymentIntent.id,
        amount: stripeAmount,
        currency,
      },
    });

    // Send notifications
    await supabase.from("communication_notifications").insert([
      {
        user_id: buyer_id,
        type: "escrow_created",
        title: "Paiement sécurisé créé",
        body: `Vos fonds (${amount} ${currency}) sont bloqués de manière sécurisée jusqu'à validation.`,
        metadata: { escrow_id: escrow.id, amount, currency },
      },
      {
        user_id: seller_id,
        type: "escrow_created",
        title: "Nouveau paiement escrow",
        body: `Un client a effectué un paiement de ${amount} ${currency} en attente de validation.`,
        metadata: { escrow_id: escrow.id, amount, currency },
      },
    ]);

    logStep("📧 Notifications sent");

    return new Response(
      JSON.stringify({
        success: true,
        status: escrow.status,
        escrow_id: escrow.id,
        payment_intent_id: paymentIntent.id,
        payment_intent_client_secret: paymentIntent.client_secret,
        requires_payment_method: paymentIntent.status === 'requires_payment_method',
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error) {
    logStep("❌ Escrow creation error", error);
    return new Response(
      JSON.stringify({
        success: false,
        error: error instanceof Error ? error.message : "Unknown error",
      }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
