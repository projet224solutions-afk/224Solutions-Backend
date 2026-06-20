/**
 * CONFIRM STRIPE DEPOSIT - Confirme et crédite le wallet après paiement carte
 * Appelé par le frontend après confirmPayment réussi
 * Vérifie le PaymentIntent côté Stripe avant de créditer
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
  console.log(`[CONFIRM-DEPOSIT] ${step}${detailsStr}`);
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    logStep("Function started");

    const stripeSecretKey = Deno.env.get("STRIPE_SECRET_KEY");
    if (!stripeSecretKey) throw new Error("STRIPE_SECRET_KEY not configured");

    // Authentifier l'utilisateur
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: req.headers.get('Authorization')! } } }
    );

    const { data: { user }, error: authError } = await supabaseClient.auth.getUser();
    if (authError || !user) throw new Error("Non autorisé");
    logStep("User authenticated", { userId: user.id });

    const { paymentIntentId } = await req.json();
    if (!paymentIntentId) throw new Error("paymentIntentId requis");

    // Vérifier le PaymentIntent côté Stripe
    const stripe = new Stripe(stripeSecretKey, {
      apiVersion: '2023-10-16',
      httpClient: Stripe.createFetchHttpClient(),
    });

    const paymentIntent = await stripe.paymentIntents.retrieve(paymentIntentId);
    logStep("PaymentIntent retrieved", { 
      status: paymentIntent.status, 
      userId: paymentIntent.metadata?.user_id,
      type: paymentIntent.metadata?.type 
    });

    // Vérifier que le paiement a réussi
    if (paymentIntent.status !== 'succeeded') {
      throw new Error(`Paiement non confirmé (status: ${paymentIntent.status})`);
    }

    // Vérifier que c'est bien l'utilisateur qui a initié le paiement
    if (paymentIntent.metadata?.user_id !== user.id) {
      throw new Error("Ce paiement ne vous appartient pas");
    }

    // Vérifier que c'est un dépôt
    if (paymentIntent.metadata?.type !== 'deposit') {
      throw new Error("Ce paiement n'est pas un dépôt wallet");
    }

    // Utiliser le service role pour créditer le wallet
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    // Chercher la transaction stripe existante
    const { data: transaction, error: txError } = await supabaseAdmin
      .from('stripe_transactions')
      .select('id, status, metadata')
      .eq('stripe_payment_intent_id', paymentIntentId)
      .single();

    if (txError || !transaction) {
      logStep("Transaction not found in DB", { paymentIntentId });
      throw new Error("Transaction non trouvée");
    }

    const walletAlreadyCredited = Boolean(transaction.metadata && (transaction.metadata as Record<string, unknown>).wallet_credited === true);

    // Éviter le double crédit réel (wallet déjà crédité)
    if (transaction.status === 'SUCCEEDED' && walletAlreadyCredited) {
      logStep("Transaction already processed (idempotent)", { transactionId: transaction.id });
      return new Response(
        JSON.stringify({ success: true, already_processed: true, message: "Dépôt déjà crédité" }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (transaction.status === 'SUCCEEDED' && !walletAlreadyCredited) {
      logStep("Transaction marked SUCCEEDED but wallet not credited yet, retrying RPC", { transactionId: transaction.id });
    }

    // Mettre à jour le statut de la transaction
    let chargeId = null;
    let last4 = null;
    let cardBrand = null;

    if (paymentIntent.latest_charge) {
      try {
        const charge = await stripe.charges.retrieve(paymentIntent.latest_charge as string);
        chargeId = charge.id;
        if (charge.payment_method_details?.card) {
          last4 = charge.payment_method_details.card.last4;
          cardBrand = charge.payment_method_details.card.brand;
        }
      } catch (e) {
        logStep("Error fetching charge details", { error: String(e) });
      }
    }

    if (transaction.status !== 'SUCCEEDED') {
      const { error: updateTxError } = await supabaseAdmin
        .from('stripe_transactions')
        .update({
          status: 'SUCCEEDED',
          stripe_charge_id: chargeId,
          last4,
          card_brand: cardBrand,
          paid_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
        })
        .eq('id', transaction.id);

      if (updateTxError) {
        throw new Error("Erreur lors de la mise à jour de la transaction: " + updateTxError.message);
      }
    }

    // Créditer le wallet via le RPC existant
    const { data: depositResult, error: depositError } = await supabaseAdmin
      .rpc('process_deposit_payment', { p_transaction_id: transaction.id });

    if (depositError) {
      logStep("Error crediting wallet", { error: depositError.message });
      throw new Error("Erreur lors du crédit du wallet: " + depositError.message);
    }

    logStep("Deposit confirmed and wallet credited", { 
      transactionId: transaction.id, 
      result: depositResult 
    });

    return new Response(
      JSON.stringify({ success: true, message: "Wallet crédité avec succès", result: depositResult }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Erreur inconnue';
    logStep("ERROR", { message: errorMessage });
    return new Response(
      JSON.stringify({ success: false, error: errorMessage }),
      { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
