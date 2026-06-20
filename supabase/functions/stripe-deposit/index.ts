/**
 * STRIPE DEPOSIT - Dépôt par carte bancaire vers wallet
 * Edge Function pour créditer le wallet d'un utilisateur via paiement carte
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
  console.log(`[STRIPE-DEPOSIT] ${step}${detailsStr}`);
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

    // Vérifier l'authentification
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

    // Récupérer les données
    const { amount, currency = 'gnf' } = await req.json();

    if (!amount || amount <= 0) {
      throw new Error("Montant invalide");
    }

    // Lire le taux dynamique depuis pdg_settings
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );
    const DEPOSIT_FEE_RATE = await getPdgFeeRate(supabaseAdmin, FEE_KEYS.DEPOSIT);

    // Calculer les frais
    const depositFee = Math.round(amount * (DEPOSIT_FEE_RATE / 100));
    const netAmount = amount - depositFee;

    logStep("Deposit details", { 
      amount, 
      depositFee,
      netAmount,
      currency,
      feeRate: DEPOSIT_FEE_RATE,
    });

    // Initialiser Stripe
    const stripe = new Stripe(stripeSecretKey, {
      apiVersion: '2023-10-16',
      httpClient: Stripe.createFetchHttpClient(),
    });

    // Créer le Payment Intent
    const paymentIntent = await stripe.paymentIntents.create({
      amount: Math.round(amount),
      currency: currency.toLowerCase(),
      automatic_payment_methods: {
        enabled: true,
      },
      metadata: {
        user_id: user.id,
        type: 'deposit',
        deposit_fee: depositFee.toString(),
        net_amount: netAmount.toString(),
        source: 'wallet_deposit',
      },
    });

    logStep("Payment Intent created", { 
      id: paymentIntent.id, 
      status: paymentIntent.status 
    });

    // Enregistrer dans stripe_transactions (supabaseAdmin déjà créé)

    const { data: transaction, error: insertError } = await supabaseAdmin
      .from('stripe_transactions')
      .insert({
        stripe_payment_intent_id: paymentIntent.id,
        buyer_id: user.id,
        seller_id: user.id, // Même utilisateur pour un dépôt
        amount: amount,
        currency: currency.toUpperCase(),
        commission_rate: DEPOSIT_FEE_RATE,
        commission_amount: depositFee,
        seller_net_amount: netAmount,
        status: 'PENDING',
        payment_method: 'card',
        metadata: {
          type: 'deposit',
          source: 'wallet_deposit',
          created_by: user.id,
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
        amount: amount,
        depositFee: depositFee,
        netAmount: netAmount,
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
