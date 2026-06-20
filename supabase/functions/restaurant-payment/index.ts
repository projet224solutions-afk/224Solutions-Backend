/**
 * RESTAURANT PAYMENT - Paiement carte bancaire pour commandes restaurant
 * Edge Function pour créer un Payment Intent avec commission plateforme
 * 224SOLUTIONS
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14.10.0?target=deno";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const logStep = (step: string, details?: Record<string, unknown>) => {
  const detailsStr = details ? ` - ${JSON.stringify(details)}` : "";
  console.log(`[RESTAURANT-PAYMENT] ${step}${detailsStr}`);
};

import { getPdgFeeRate, FEE_KEYS } from "../_shared/pdg-fees.ts";

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    logStep("Function started");

    const stripeSecretKey = Deno.env.get("STRIPE_SECRET_KEY");
    if (!stripeSecretKey) {
      throw new Error("STRIPE_SECRET_KEY not configured");
    }

    // Authentification
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      {
        global: {
          headers: { Authorization: req.headers.get('Authorization')! },
        },
      }
    );

    const { data: { user }, error: authError } = await supabaseClient.auth.getUser();
    if (authError || !user) {
      throw new Error("Non autorisé");
    }
    logStep("User authenticated", { userId: user.id });

    const {
      amount,
      currency = 'gnf',
      orderId,
      serviceId,
      description,
      items,
    } = await req.json();

    if (!amount || amount <= 0) {
      throw new Error("Montant invalide");
    }

    if (!serviceId) {
      throw new Error("Service ID requis");
    }

    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    // Récupérer le propriétaire du service restaurant
    const { data: service, error: serviceError } = await supabaseAdmin
      .from('professional_services')
      .select('user_id')
      .eq('id', serviceId)
      .single();

    if (serviceError || !service) {
      throw new Error("Service restaurant introuvable");
    }

    const sellerId = service.user_id;

    // Commission restaurant (utiliser le taux dynamique)
    const commissionRate = await getPdgFeeRate(supabaseAdmin, FEE_KEYS.PURCHASE_COMMISSION);
    const commissionAmount = Math.round(amount * (commissionRate / 100));
    const totalAmount = amount + commissionAmount;
    const sellerNetAmount = amount;

    logStep("Payment details", {
      productAmount: amount,
      commissionRate,
      commissionAmount,
      totalAmount,
      sellerNetAmount,
      sellerId,
      orderId,
    });

    // Stripe
    const stripe = new Stripe(stripeSecretKey, {
      apiVersion: '2023-10-16',
      httpClient: Stripe.createFetchHttpClient(),
    });

    const paymentIntent = await stripe.paymentIntents.create({
      amount: Math.round(totalAmount),
      currency: currency.toLowerCase(),
      automatic_payment_methods: { enabled: true },
      metadata: {
        order_id: orderId || '',
        buyer_id: user.id,
        seller_id: sellerId,
        service_id: serviceId,
        product_amount: amount.toString(),
        commission_rate: commissionRate.toString(),
        commission_amount: commissionAmount.toString(),
        total_amount: totalAmount.toString(),
        seller_net_amount: sellerNetAmount.toString(),
        source: 'restaurant',
        description: description || 'Commande restaurant',
      },
    });

    logStep("Payment Intent created", {
      id: paymentIntent.id,
      status: paymentIntent.status,
    });

    // Enregistrer dans stripe_transactions
    const { data: transaction, error: insertError } = await supabaseAdmin
      .from('stripe_transactions')
      .insert({
        stripe_payment_intent_id: paymentIntent.id,
        buyer_id: user.id,
        seller_id: sellerId,
        amount: totalAmount,
        currency: currency.toUpperCase(),
        commission_rate: commissionRate,
        commission_amount: commissionAmount,
        seller_net_amount: sellerNetAmount,
        status: 'PENDING',
        order_id: orderId || null,
        payment_method: 'card',
        metadata: {
          description: description || 'Commande restaurant',
          source: 'restaurant',
          service_id: serviceId,
          created_by: user.id,
          items: items || [],
        },
      })
      .select('id')
      .single();

    if (insertError) {
      logStep("Error inserting transaction", { error: insertError.message });
    } else {
      logStep("Transaction recorded", { transactionId: transaction?.id });
    }

    return new Response(
      JSON.stringify({
        success: true,
        clientSecret: paymentIntent.client_secret,
        paymentIntentId: paymentIntent.id,
        transactionId: transaction?.id,
        commissionRate,
        commissionAmount,
        sellerNetAmount,
        productAmount: amount,
        totalAmount,
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
