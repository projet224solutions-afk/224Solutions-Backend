/**
 * TAXI-MOTO: Payment processing
 * Supporte: Card (Stripe), Orange Money, Wallet 224Solutions
 * 224SOLUTIONS
 */

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14.10.0?target=deno";
import { getPdgFeeRate, FEE_KEYS } from "../_shared/pdg-fees.ts";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const logStep = (step: string, details?: unknown) => {
  console.log(`[TAXI-PAYMENT] ${step}`, details ? JSON.stringify(details) : '');
};

// Fallback si pdg_settings n'a pas de taux taxi
const DEFAULT_TAXI_FEE_RATE = 15;

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

   // Client admin pour les opérations DB
   const supabaseAdmin = createClient(
     Deno.env.get("SUPABASE_URL") ?? "",
     Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
   );

   // Client authentifié pour vérifier l'utilisateur
   const supabaseClient = createClient(
     Deno.env.get("SUPABASE_URL") ?? "",
     Deno.env.get("SUPABASE_ANON_KEY") ?? "",
     {
       global: {
         headers: { Authorization: req.headers.get('Authorization')! },
       },
     }
   );

  try {
    logStep('Payment started');

    const { data: { user }, error: authError } = await supabaseClient.auth.getUser();
    if (authError || !user) throw new Error("Authentication failed");
    
    logStep('User authenticated', { userId: user.id });

    const { rideId, paymentMethod, idempotencyKey } = await req.json();
    if (!rideId || !paymentMethod) throw new Error("rideId and paymentMethod required");

    logStep('Processing payment', { rideId, paymentMethod, idempotencyKey });

    // Check for duplicate
    if (idempotencyKey) {
      const { data: existing } = await supabaseAdmin
        .from('taxi_transactions')
        .select('id, status')
        .eq('idempotency_key', idempotencyKey)
        .maybeSingle();

      if (existing) {
        logStep('Duplicate request detected', { existingId: existing.id });
        return new Response(
          JSON.stringify({ success: true, transaction: existing }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // Get ride details
    const { data: ride, error: rideError } = await supabaseAdmin
      .from('taxi_trips')
      .select('*')
      .eq('id', rideId)
      .single();

    if (rideError || !ride) throw new Error('Ride not found');

    // Récupérer le taux de commission dynamique pour le taxi
    // On utilise une clé dédiée si elle existe, sinon fallback
    let PLATFORM_FEE_RATE = DEFAULT_TAXI_FEE_RATE;
    try {
      const dynamicRate = await getPdgFeeRate(supabaseAdmin, 'commission_taxi');
      // Si la clé n'existe pas, getPdgFeeRate retournera 0 (pas dans DEFAULT_FEES)
      // Dans ce cas, utiliser le fallback
      if (dynamicRate > 0) {
        PLATFORM_FEE_RATE = dynamicRate;
      }
    } catch {
      // Utiliser le taux par défaut
    }

    const totalAmount = ride.price_total;
    const platformFee = Math.round(totalAmount * (PLATFORM_FEE_RATE / 100));
    const driverShare = totalAmount - platformFee;

    logStep('Ride found', { 
      price: totalAmount, 
      platformFee,
      platformFeeRate: PLATFORM_FEE_RATE,
      driverShare,
      driverId: ride.driver_id 
    });

    // Create transaction record
    const { data: transaction, error: txError } = await supabaseClient
      .from('taxi_transactions')
      .insert({
        ride_id: rideId,
        customer_id: ride.customer_id,
        driver_id: ride.driver_id,
        amount: totalAmount,
        currency: 'GNF',
        payment_method: paymentMethod,
        driver_share: driverShare,
        platform_fee: platformFee,
        status: 'processing',
        idempotency_key: idempotencyKey,
        metadata: { user_id: user.id, platform_fee_rate: PLATFORM_FEE_RATE }
      })
      .select()
      .single();

    if (txError) throw txError;

    logStep('Transaction created', { txId: transaction.id });

    // Process based on payment method
    let paymentResult;

    switch (paymentMethod) {
      case 'wallet': {
        logStep('Processing wallet payment');
        
        // Get customer wallet
        const { data: wallet } = await supabaseClient
          .from('wallets')
          .select('balance, currency')
          .eq('user_id', ride.customer_id)
          .eq('currency', 'GNF')
          .single();

        if (!wallet || wallet.balance < totalAmount) {
          throw new Error('Solde wallet insuffisant');
        }

        // Débiter le wallet client
        await supabaseClient
          .from('wallets')
          .update({
            balance: wallet.balance - totalAmount,
            last_transaction_at: new Date().toISOString(),
          })
          .eq('user_id', ride.customer_id)
          .eq('currency', 'GNF');

        // Créditer le wallet chauffeur (via RPC pour atomicité)
        const { error: walletError } = await supabaseAdmin.rpc('process_wallet_transaction', {
          p_sender_id: ride.customer_id,
          p_receiver_id: ride.driver_id,
          p_amount: driverShare,
          p_currency: 'GNF',
          p_description: `Course taxi ${rideId} - Commission plateforme: ${platformFee} GNF`
        });

        if (walletError) throw walletError;

        // Marquer transaction comme complétée
        await supabaseClient
          .from('taxi_transactions')
          .update({ 
            status: 'completed', 
            completed_at: new Date().toISOString() 
          })
          .eq('id', transaction.id);

        await supabaseClient
          .from('taxi_trips')
          .update({ payment_status: 'paid' })
          .eq('id', rideId);

        paymentResult = { success: true, method: 'wallet' };
        break;
      }

      case 'card': {
        logStep('Processing card payment via Stripe');
        
        const stripeSecretKey = Deno.env.get("STRIPE_SECRET_KEY");
        if (!stripeSecretKey) throw new Error("Stripe not configured");

        const stripe = new Stripe(stripeSecretKey, {
          apiVersion: '2023-10-16',
          httpClient: Stripe.createFetchHttpClient(),
        });

        // Créer Payment Intent avec metadata pour le webhook
        const paymentIntent = await stripe.paymentIntents.create({
          amount: Math.round(totalAmount),
          currency: 'gnf',
          automatic_payment_methods: {
            enabled: true,
          },
          metadata: {
            source: 'taxi',
            ride_id: rideId,
            customer_id: ride.customer_id,
            driver_id: ride.driver_id,
            driver_share: driverShare.toString(),
            platform_fee: platformFee.toString(),
            transaction_id: transaction.id,
          }
        });

        // Update transaction with provider info
        await supabaseClient
          .from('taxi_transactions')
          .update({
            payment_provider: 'stripe',
            provider_tx_id: paymentIntent.id,
            metadata: { 
              ...transaction.metadata, 
              payment_intent_id: paymentIntent.id,
              client_secret: paymentIntent.client_secret 
            }
          })
          .eq('id', transaction.id);

        paymentResult = { 
          success: true, 
          method: 'card',
          client_secret: paymentIntent.client_secret,
          payment_intent_id: paymentIntent.id,
          amount: totalAmount,
          platformFee: platformFee,
          driverShare: driverShare
        };
        break;
      }

      case 'orange_money': {
        logStep('Processing Orange Money payment');
        
        // TODO: Integrate with Orange Money API
        // For now, mark as processing and wait for webhook
        
        paymentResult = { 
          success: true, 
          method: 'orange_money',
          status: 'processing',
          message: 'Confirmez le paiement sur votre téléphone'
        };
        break;
      }

      case 'cash': {
        logStep('Cash payment - marking as pending');
        
        await supabaseClient
          .from('taxi_transactions')
          .update({ status: 'pending' })
          .eq('id', transaction.id);

        paymentResult = { success: true, method: 'cash', status: 'pending' };
        break;
      }

      default:
        throw new Error('Méthode de paiement invalide');
    }

    logStep('Payment processed', paymentResult);

    // Notify driver
    if (ride.driver_id && paymentMethod !== 'card') {
      const { data: driver } = await supabaseClient
        .from('taxi_drivers')
        .select('user_id')
        .eq('id', ride.driver_id)
        .single();

      if (driver) {
        await supabaseAdmin.rpc('create_taxi_notification', {
          p_user_id: driver.user_id,
          p_type: 'payment_received',
          p_title: 'Paiement reçu',
          p_body: `Paiement de ${driverShare} GNF confirmé (${totalAmount} GNF - ${platformFee} GNF commission)`,
          p_data: { rideId, amount: driverShare, platformFee },
          p_ride_id: rideId
        });
      }
    }

    return new Response(
      JSON.stringify({ success: true, transaction, payment: paymentResult }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    logStep('ERROR', { message: errorMessage });
    return new Response(
      JSON.stringify({ error: errorMessage }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
