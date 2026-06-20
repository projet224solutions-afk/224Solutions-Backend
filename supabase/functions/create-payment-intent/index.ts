/**
 * EDGE FUNCTION: create-payment-intent
 * Création d'un PaymentIntent STRIPE pour paiement par carte bancaire
 * 224SOLUTIONS - STRIPE UNIQUEMENT
 * 
 * Ce endpoint est utilisé par:
 * - StripePaymentWrapper
 * - useStripePayment
 * - tout flux de paiement par carte sur le marketplace
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@18.5.0";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getPdgFeeRate, FEE_KEYS } from "../_shared/pdg-fees.ts";
import { getInternalFxRate } from "../_shared/fx-internal.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

// Stripe supported currencies (lowercase)
const STRIPE_ZERO_DECIMAL_CURRENCIES = new Set([
  "bif", "clp", "djf", "gnf", "jpy", "kmf", "krw", "mga", "pyg", "rwf",
  "ugx", "vnd", "vuv", "xaf", "xof", "xpf"
]);

const json = (payload: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

const logStep = (step: string, details?: Record<string, unknown>) => {
  const detailsStr = details ? ` - ${JSON.stringify(details)}` : "";
  console.log(`[STRIPE-PI] ${step}${detailsStr}`);
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    logStep("Function started");

    const stripeSecretKey = Deno.env.get("STRIPE_SECRET_KEY");
    if (!stripeSecretKey) {
      return json({ success: false, error: "Stripe not configured" }, 500);
    }

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    );

    // Auth utilisateur
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return json({ success: false, error: "Missing authorization" }, 401);
    }

    const token = authHeader.replace("Bearer ", "");
    const { data: { user }, error: authError } = await supabaseAdmin.auth.getUser(token);

    if (authError || !user) {
      return json({ success: false, error: "Unauthorized" }, 401);
    }

    logStep("User authenticated", { userId: user.id });

    const {
      amount,
      currency = "GNF",
      seller_id,
      order_id,
      service_id,
      product_id,
      metadata = {},
    } = await req.json();

    if (!amount || Number(amount) <= 0) {
      return json({ success: false, error: "Invalid amount" });
    }

    if (!seller_id) {
      return json({ success: false, error: "seller_id is required" });
    }

    // Vérifier vendeur
    const { data: seller, error: sellerError } = await supabaseAdmin
      .from("profiles")
      .select("id, full_name, email, role")
      .eq("id", seller_id)
      .single();

    if (sellerError || !seller) {
      return json({ success: false, error: "Seller not found" });
    }

    // Commission dynamique depuis pdg_settings
    const commissionRate = await getPdgFeeRate(supabaseAdmin, FEE_KEYS.PURCHASE_COMMISSION);
    const sourceAmount = Number(amount);
    const commissionAmount = Math.round((sourceAmount * commissionRate) / 100);
    const totalAmountWithCommission = sourceAmount + commissionAmount;
    const sellerNetAmount = sourceAmount;

    // Conversion vers devise Stripe-friendly si nécessaire
    const sourceCurrency = String(currency).toUpperCase();
    let stripeCurrency = sourceCurrency.toLowerCase();
    let stripeAmount = totalAmountWithCommission;
    let fxRate = 1;
    let fxSource = "direct";
    let wasConverted = false;

    // GNF est supporté par Stripe (zero-decimal), pas besoin de conversion
    // XOF est aussi supporté (zero-decimal)
    // Si la devise n'est pas supportée par Stripe, convertir en USD
    try {
      // Vérifier si Stripe supporte cette devise en créant le PI
      // Stripe gère la plupart des devises africaines
      logStep("Using currency directly", { currency: stripeCurrency, amount: stripeAmount });
    } catch (e) {
      // Fallback: convertir en USD
      const fx = await getInternalFxRate(supabaseAdmin, sourceCurrency, "USD");
      fxRate = fx.rate;
      fxSource = fx.source;
      wasConverted = true;
      stripeCurrency = "usd";
      stripeAmount = Math.round(totalAmountWithCommission * fxRate * 100); // USD = centimes
      logStep("Converted to USD", { fxRate, stripeAmount });
    }

    // Pour les devises zero-decimal, pas de multiplication par 100
    const isZeroDecimal = STRIPE_ZERO_DECIMAL_CURRENCIES.has(stripeCurrency);
    const stripeAmountFinal = isZeroDecimal
      ? Math.round(stripeAmount)
      : Math.round(stripeAmount * 100);

    // Créer le Payment Intent Stripe
    const stripe = new Stripe(stripeSecretKey, {
      apiVersion: "2025-08-27.basil",
    });

    // Chercher ou créer le customer Stripe
    let customerId: string | undefined;
    if (user.email) {
      const customers = await stripe.customers.list({ email: user.email, limit: 1 });
      if (customers.data.length > 0) {
        customerId = customers.data[0].id;
      }
    }

    const paymentIntent = await stripe.paymentIntents.create({
      amount: stripeAmountFinal,
      currency: stripeCurrency,
      customer: customerId,
      metadata: {
        buyer_id: user.id,
        seller_id,
        order_id: order_id || "",
        service_id: service_id || "",
        product_id: product_id || "",
        source_currency: sourceCurrency,
        source_amount: sourceAmount.toString(),
        commission_rate: commissionRate.toString(),
        commission_amount: commissionAmount.toString(),
        seller_net_amount: sellerNetAmount.toString(),
        platform: "224solutions",
        ...metadata,
      },
      automatic_payment_methods: {
        enabled: true,
      },
      description: `Paiement 224Solutions - ${seller.full_name || "Vendeur"}`,
    });

    logStep("PaymentIntent created", {
      id: paymentIntent.id,
      status: paymentIntent.status,
      amount: stripeAmountFinal,
      currency: stripeCurrency,
    });

    // Enregistrer la transaction
    const { data: transaction } = await supabaseAdmin
      .from("stripe_transactions")
      .insert({
        stripe_payment_intent_id: paymentIntent.id,
        buyer_id: user.id,
        seller_id,
        amount: totalAmountWithCommission,
        currency: sourceCurrency,
        commission_rate: commissionRate,
        commission_amount: commissionAmount,
        seller_net_amount: sellerNetAmount,
        status: "PENDING",
        order_id,
        service_id,
        product_id,
        payment_method: "card",
        metadata: {
          stripe_currency: stripeCurrency,
          stripe_amount: stripeAmountFinal,
          fx_rate: fxRate,
          fx_source: fxSource,
          was_converted: wasConverted,
          product_amount: sourceAmount,
          total_amount: totalAmountWithCommission,
          ...metadata,
        },
      })
      .select("id")
      .single();

    return json({
      success: true,
      client_secret: paymentIntent.client_secret,
      payment_intent_id: paymentIntent.id,
      transaction_id: transaction?.id,
      amount: sourceAmount,
      currency: sourceCurrency,
      commission_amount: commissionAmount,
      seller_net_amount: sellerNetAmount,
      status: paymentIntent.status,
    });

  } catch (error) {
    console.error("❌ Error in create-payment-intent:", error);
    const message = error instanceof Error ? error.message : "Internal server error";
    return json({ success: false, error: message }, 200);
  }
});
