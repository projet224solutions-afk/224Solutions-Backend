/**
 * STRIPE MARKETPLACE PAYMENT
 * Paiement par carte pour achats marketplace (multi-vendeurs)
 * Crée un seul PaymentIntent global, stocke le détail vendeurs en métadonnées
 * 224SOLUTIONS
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14.10.0?target=deno";
import { getPdgFeeRate, FEE_KEYS } from "../_shared/pdg-fees.ts";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version',
};

const logStep = (step: string, details?: Record<string, unknown>) => {
  console.log(`[STRIPE-MARKETPLACE] ${step}${details ? ` - ${JSON.stringify(details)}` : ""}`);
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    logStep("Function started");

    const stripeSecretKey = Deno.env.get("STRIPE_SECRET_KEY");
    if (!stripeSecretKey) throw new Error("STRIPE_SECRET_KEY not configured");

    // Auth
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: req.headers.get('Authorization')! } } }
    );

    const { data: { user }, error: authError } = await supabaseClient.auth.getUser();
    if (authError || !user) throw new Error("Non autorisé");
    logStep("User authenticated", { userId: user.id });

    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    const {
      amount,
      currency = 'gnf',
      cartItems = [],
      description,
    } = await req.json();

    if (!amount || amount <= 0) throw new Error("Montant invalide");

    // Commission dynamique
    const commissionRate = await getPdgFeeRate(supabaseAdmin, FEE_KEYS.PURCHASE_COMMISSION);
    const commissionAmount = Math.round(amount * (commissionRate / 100));
    const totalAmount = amount + commissionAmount;

    logStep("Payment details", { productAmount: amount, commissionRate, commissionAmount, totalAmount });

    // Construire le résumé vendeurs pour les métadonnées
    // cartItems: [{ vendorId, vendorTotal, items: [...] }]
    const vendorSummary: Record<string, number> = {};
    if (cartItems.length > 0) {
      for (const item of cartItems) {
        const vid = item.vendorId || 'unknown';
        vendorSummary[vid] = (vendorSummary[vid] || 0) + (item.price * (item.quantity || 1));
      }
    }

    const stripe = new Stripe(stripeSecretKey, {
      apiVersion: '2023-10-16',
      httpClient: Stripe.createFetchHttpClient(),
    });

    const paymentIntent = await stripe.paymentIntents.create({
      amount: Math.round(totalAmount),
      currency: currency.toLowerCase(),
      automatic_payment_methods: { enabled: true },
      metadata: {
        source: 'marketplace',
        buyer_id: user.id,
        product_amount: amount.toString(),
        commission_rate: commissionRate.toString(),
        commission_amount: commissionAmount.toString(),
        total_amount: totalAmount.toString(),
        vendor_count: Object.keys(vendorSummary).length.toString(),
        vendor_summary: JSON.stringify(vendorSummary).substring(0, 500),
        items_count: cartItems.length.toString(),
        description: description || 'Achat Marketplace 224Solutions',
      },
    });

    logStep("Payment Intent created", { id: paymentIntent.id });

    // Enregistrer la transaction
    const { data: transaction, error: insertError } = await supabaseAdmin
      .from('stripe_transactions')
      .insert({
        stripe_payment_intent_id: paymentIntent.id,
        buyer_id: user.id,
        seller_id: Object.keys(vendorSummary)[0] || null,
        amount: totalAmount,
        currency: currency.toUpperCase(),
        commission_rate: commissionRate,
        commission_amount: commissionAmount,
        seller_net_amount: amount,
        status: 'PENDING',
        payment_method: 'card',
        metadata: {
          source: 'marketplace',
          vendor_summary: vendorSummary,
          cart_items: cartItems.map((i: any) => ({
            id: i.id, name: i.name, price: i.price,
            quantity: i.quantity || 1, vendorId: i.vendorId,
          })),
          product_amount: amount,
          total_amount: totalAmount,
        },
      })
      .select('id')
      .single();

    if (insertError) {
      logStep("Error inserting transaction", { error: insertError.message });
    }

    return new Response(
      JSON.stringify({
        success: true,
        clientSecret: paymentIntent.client_secret,
        paymentIntentId: paymentIntent.id,
        transactionId: transaction?.id,
        commissionRate,
        commissionAmount,
        totalAmount,
        productAmount: amount,
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Erreur inconnue';
    logStep("ERROR", { message: errorMessage });
    return new Response(
      JSON.stringify({ success: false, error: errorMessage }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
