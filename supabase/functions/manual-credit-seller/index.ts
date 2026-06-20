/**
 * EDGE FUNCTION: manual-credit-seller
 * Créditer manuellement le wallet vendeur après paiement réussi
 * Solution temporaire en attendant configuration webhook Stripe
 * 224SOLUTIONS
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import Stripe from 'https://esm.sh/stripe@14.10.0?target=deno';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface ManualCreditRequest {
  payment_intent_id: string;
}

serve(async (req) => {
  // CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    // Initialize Supabase client
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Get authenticated user (admin only)
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: 'Missing authorization header' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const token = authHeader.replace('Bearer ', '');
    const { data: { user }, error: authError } = await supabase.auth.getUser(token);

    if (authError || !user) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Vérifier que l'utilisateur est admin/PDG
    const { data: profile } = await supabase
      .from('profiles')
      .select('role')
      .eq('id', user.id)
      .single();

    if (!profile || !['CEO', 'SUPER_ADMIN', 'PDG', 'admin'].includes(profile.role)) {
      return new Response(
        JSON.stringify({ error: 'Access denied: Admin only' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Parse request
    const { payment_intent_id }: ManualCreditRequest = await req.json();

    if (!payment_intent_id) {
      return new Response(
        JSON.stringify({ error: 'payment_intent_id is required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    console.log('🔍 Recherche transaction pour Payment Intent:', payment_intent_id);

    // 1. Récupérer transaction
    const { data: transaction, error: fetchError } = await supabase
      .from('stripe_transactions')
      .select('*')
      .eq('stripe_payment_intent_id', payment_intent_id)
      .single();

    if (fetchError || !transaction) {
      return new Response(
        JSON.stringify({ 
          error: 'Transaction not found',
          payment_intent_id 
        }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    console.log('✅ Transaction trouvée:', transaction.id);

    // 2. Vérifier si déjà traitée
    if (transaction.status === 'SUCCEEDED') {
      return new Response(
        JSON.stringify({ 
          warning: 'Payment already processed',
          transaction,
          wallet_already_credited: true
        }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // 3. Vérifier le statut réel sur Stripe
    const stripeSecretKey = Deno.env.get('STRIPE_SECRET_KEY')!;
    const stripe = new Stripe(stripeSecretKey, {
      apiVersion: '2023-10-16',
      httpClient: Stripe.createFetchHttpClient(),
    });

    const paymentIntent = await stripe.paymentIntents.retrieve(payment_intent_id);

    console.log('📊 Statut Stripe:', paymentIntent.status);

    if (paymentIntent.status !== 'succeeded') {
      return new Response(
        JSON.stringify({ 
          error: 'Payment not succeeded on Stripe',
          stripe_status: paymentIntent.status,
          transaction_status: transaction.status
        }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // 4. Récupérer détails charge
    let chargeId = null;
    let last4 = null;
    let cardBrand = null;
    let threeDsStatus = null;

    if (paymentIntent.latest_charge) {
      const charge = await stripe.charges.retrieve(paymentIntent.latest_charge as string);
      chargeId = charge.id;
      
      if (charge.payment_method_details?.card) {
        last4 = charge.payment_method_details.card.last4;
        cardBrand = charge.payment_method_details.card.brand;
        threeDsStatus = charge.payment_method_details.card.three_d_secure?.authentication_flow || null;
      }
    }

    // 5. Mettre à jour transaction
    const { error: updateError } = await supabase
      .from('stripe_transactions')
      .update({
        status: 'SUCCEEDED',
        stripe_charge_id: chargeId,
        last4: last4,
        card_brand: cardBrand,
        three_ds_status: threeDsStatus,
        paid_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      })
      .eq('id', transaction.id);

    if (updateError) {
      console.error('❌ Error updating transaction:', updateError);
      throw updateError;
    }

    console.log('✅ Transaction mise à jour');

    // 6. Traiter le paiement et créditer wallets
    const { error: processError } = await supabase.rpc('process_successful_payment', {
      p_transaction_id: transaction.id
    });

    if (processError) {
      console.error('❌ Error processing payment:', processError);
      throw processError;
    }

    console.log('✅ Wallets crédités avec succès');

    // 7. Vérifier wallet vendeur après crédit
    const { data: sellerWallet } = await supabase
      .from('wallets')
      .select('available_balance, total_earned, total_transactions')
      .eq('user_id', transaction.seller_id)
      .single();

    return new Response(
      JSON.stringify({
        success: true,
        message: 'Wallet vendeur crédité avec succès',
        transaction: {
          id: transaction.id,
          amount: transaction.amount,
          commission_amount: transaction.commission_amount,
          seller_net_amount: transaction.seller_net_amount,
          status: 'SUCCEEDED',
          seller_id: transaction.seller_id,
          buyer_id: transaction.buyer_id,
        },
        seller_wallet: sellerWallet,
        stripe_details: {
          payment_intent_id,
          charge_id: chargeId,
          card_last4: last4,
          card_brand: cardBrand,
          three_ds: threeDsStatus,
        },
        credited_at: new Date().toISOString(),
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    console.error('❌ Error in manual-credit-seller:', error);
    const message = error instanceof Error ? error.message : 'Internal server error';
    return new Response(
      JSON.stringify({ 
        error: 'Manual credit failed', 
        details: message 
      }),
      { 
        status: 500, 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
      }
    );
  }
});
