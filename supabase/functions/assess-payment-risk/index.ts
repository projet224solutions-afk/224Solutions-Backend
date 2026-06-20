// =====================================================
// EDGE FUNCTION: ÉVALUATION DES RISQUES DE PAIEMENT
// =====================================================
// Description: Appelée par le webhook Stripe pour calculer
//              le Trust Score et décider du déblocage des fonds
// =====================================================

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import Stripe from 'https://esm.sh/stripe@13.6.0?target=deno';

const STRIPE_KEY = Deno.env.get('STRIPE_SECRET_KEY');
if (!STRIPE_KEY) throw new Error("CRITICAL: STRIPE_SECRET_KEY not configured");
const stripe = new Stripe(STRIPE_KEY, {
  apiVersion: '2023-10-16',
  httpClient: Stripe.createFetchHttpClient(),
});

const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

serve(async (req) => {
  // CORS headers
  if (req.method === 'OPTIONS') {
    return new Response('ok', {
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type, Authorization',
      },
    });
  }

  try {
    const { transactionId, paymentIntentId } = await req.json();

    if (!transactionId || !paymentIntentId) {
      throw new Error('transactionId and paymentIntentId required');
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    console.log(`🔍 Assessing risk for transaction: ${transactionId}`);

    // 1. RÉCUPÉRER LES DONNÉES DE LA TRANSACTION
    const { data: transaction, error: txError } = await supabase
      .from('stripe_transactions')
      .select('*')
      .eq('id', transactionId)
      .single();

    if (txError || !transaction) {
      throw new Error(`Transaction not found: ${txError?.message}`);
    }

    console.log(`📋 Transaction found: ${transaction.amount} XOF`);

    // 2. DOUBLE VÉRIFICATION AVEC STRIPE API
    console.log('🔒 Double verification with Stripe API...');
    
    const paymentIntent = await stripe.paymentIntents.retrieve(paymentIntentId);

    // Vérifications strictes
    const webhookAmount = transaction.amount;
    const apiAmount = paymentIntent.amount;
    const webhookCurrency = transaction.currency || 'xof';
    const apiCurrency = paymentIntent.currency;
    const webhookStatus = transaction.payment_status;
    const apiStatus = paymentIntent.status;

    if (webhookAmount !== apiAmount) {
      console.error(`⚠️ AMOUNT MISMATCH: webhook=${webhookAmount}, api=${apiAmount}`);
      await logFraudSignal(supabase, transactionId, 'SUSPICIOUS_PATTERN', 10, 
        `Montant incohérent: webhook=${webhookAmount}, API=${apiAmount}`);
      return createBlockedResponse('Amount mismatch detected');
    }

    if (webhookCurrency.toLowerCase() !== apiCurrency.toLowerCase()) {
      console.error(`⚠️ CURRENCY MISMATCH: webhook=${webhookCurrency}, api=${apiCurrency}`);
      await logFraudSignal(supabase, transactionId, 'SUSPICIOUS_PATTERN', 10,
        `Devise incohérente: webhook=${webhookCurrency}, API=${apiCurrency}`);
      return createBlockedResponse('Currency mismatch detected');
    }

    if (webhookStatus !== 'SUCCEEDED' || apiStatus !== 'succeeded') {
      console.error(`⚠️ STATUS ISSUE: webhook=${webhookStatus}, api=${apiStatus}`);
      return createBlockedResponse('Payment status invalid');
    }

    // Vérifier que le paiement a bien été effectué
    const charges = paymentIntent.charges?.data || [];
    const paidCharge = charges.find((c: any) => c.paid === true);
    
    if (!paidCharge) {
      console.error('⚠️ NO PAID CHARGE FOUND');
      await logFraudSignal(supabase, transactionId, 'SUSPICIOUS_PATTERN', 10,
        'Aucune charge payée trouvée dans le PaymentIntent');
      return createBlockedResponse('No paid charge found');
    }

    console.log('✅ Double verification passed');

    // 3. CALCULER LE TRUST SCORE
    console.log('🎯 Calculating Trust Score...');

    const { data: scoreData, error: scoreError } = await supabase
      .rpc('calculate_payment_trust_score', {
        p_transaction_id: transactionId,
        p_buyer_id: transaction.buyer_id,
        p_seller_id: transaction.seller_id,
        p_amount: transaction.amount,
        p_card_last4: transaction.last4 || 'XXXX',
      });

    if (scoreError) {
      console.error('Error calculating trust score:', scoreError);
      throw scoreError;
    }

    const {
      trust_score,
      risk_level,
      decision,
      auto_blocked,
      block_reasons,
      random_review,
      random_seed,
      factors,
    } = scoreData;

    console.log(`📊 Trust Score: ${trust_score}/100 (${risk_level})`);
    console.log(`🎲 Decision: ${decision}${random_review ? ' (RANDOM REVIEW)' : ''}`);

    // 4. ENREGISTRER L'ÉVALUATION DES RISQUES
    const { data: assessment, error: assessError } = await supabase
      .from('payment_risk_assessments')
      .insert({
        transaction_id: transactionId,
        trust_score,
        risk_level,
        decision,
        auto_blocked,
        block_reasons,
        random_review,
        random_seed,
        user_age_days: factors.user_age_days,
        user_age_score: factors.user_age_score,
        card_usage_count: factors.card_usage_count,
        card_history_score: factors.card_history_score,
        kyc_verified: factors.kyc_verified,
        kyc_score: factors.kyc_score,
        amount_deviation: factors.amount_deviation,
        amount_risk_score: factors.amount_risk_score,
        chargeback_history: factors.chargeback_count,
        chargeback_score: factors.chargeback_score,
        details: factors,
      })
      .select()
      .single();

    if (assessError) {
      console.error('Error saving assessment:', assessError);
      throw assessError;
    }

    // 5. TRAITER SELON LA DÉCISION

    if (decision === 'BLOCKED') {
      console.log('🚫 PAYMENT BLOCKED');
      
      // Créer des signaux de fraude pour chaque raison de blocage
      for (const reason of block_reasons) {
        if (reason.includes('7 jours')) {
          await logFraudSignal(supabase, transactionId, 'NEW_SELLER', 8, reason);
        } else if (reason.includes('5x')) {
          await logFraudSignal(supabase, transactionId, 'UNUSUAL_AMOUNT', 9, reason);
        }
      }

      return new Response(
        JSON.stringify({
          success: false,
          decision: 'BLOCKED',
          trust_score,
          reasons: block_reasons,
          assessment_id: assessment.id,
        }),
        {
          headers: { 'Content-Type': 'application/json' },
          status: 403,
        }
      );
    }

    if (decision === 'ADMIN_REVIEW') {
      console.log('👨‍💼 REQUIRES ADMIN REVIEW');
      
      // Récupérer le wallet du vendeur
      const { data: wallet } = await supabase
        .from('wallets')
        .select('id')
        .eq('user_id', transaction.seller_id)
        .single();

      if (!wallet) {
        throw new Error('Seller wallet not found');
      }

      // Créer une planification en statut PENDING (attend validation admin)
      const { data: schedule } = await supabase
        .from('funds_release_schedule')
        .insert({
          transaction_id: transactionId,
          wallet_id: wallet.id,
          amount_held: transaction.seller_net_amount,
          amount_to_release: transaction.seller_net_amount,
          status: 'PENDING',
          release_type: 'MANUAL',
        })
        .select()
        .single();

      // Créditer le pending_balance via RPC
      await supabase.rpc('increment_pending_balance', {
        p_wallet_id: wallet.id,
        p_amount: transaction.seller_net_amount,
      });

      console.log(`⏳ Funds held in pending_balance: ${transaction.seller_net_amount} XOF`);

      // Créer un signal de fraude si le contrôle est aléatoire
      if (random_review) {
        await logFraudSignal(supabase, transactionId, 'SUSPICIOUS_PATTERN', 3,
          `Contrôle aléatoire (${(random_seed * 100).toFixed(2)}%)`);
      }

      return new Response(
        JSON.stringify({
          success: true,
          decision: 'ADMIN_REVIEW',
          trust_score,
          random_review,
          schedule_id: schedule.id,
          assessment_id: assessment.id,
          message: 'Payment requires admin review before fund release',
        }),
        { headers: { 'Content-Type': 'application/json' } }
      );
    }

    if (decision === 'AUTO_APPROVED') {
      console.log('✅ AUTO APPROVED with smart delay');

      // Récupérer le wallet du vendeur
      const { data: wallet } = await supabase
        .from('wallets')
        .select('id')
        .eq('user_id', transaction.seller_id)
        .single();

      if (!wallet) {
        throw new Error('Seller wallet not found');
      }

      // Planifier la libération avec smart delay
      const { data: scheduleData, error: scheduleError } = await supabase
        .rpc('schedule_funds_release', {
          p_transaction_id: transactionId,
          p_wallet_id: wallet.id,
          p_amount: transaction.seller_net_amount,
          p_trust_score: trust_score,
        });

      if (scheduleError) {
        console.error('Error scheduling release:', scheduleError);
        throw scheduleError;
      }

      const releaseId = scheduleData;

      // Récupérer les détails du schedule
      const { data: schedule } = await supabase
        .from('funds_release_schedule')
        .select('*')
        .eq('id', releaseId)
        .single();

      // Créditer le pending_balance via RPC
      await supabase.rpc('increment_pending_balance', {
        p_wallet_id: wallet.id,
        p_amount: transaction.seller_net_amount,
      });

      const delayMinutes = Math.round(
        (new Date(schedule.scheduled_release_at).getTime() - new Date().getTime()) / 60000
      );

      console.log(`⏰ Release scheduled in ${delayMinutes} minutes`);

      return new Response(
        JSON.stringify({
          success: true,
          decision: 'AUTO_APPROVED',
          trust_score,
          schedule_id: releaseId,
          scheduled_release_at: schedule.scheduled_release_at,
          delay_minutes: delayMinutes,
          assessment_id: assessment.id,
          message: `Funds will be automatically released in ${delayMinutes} minutes`,
        }),
        { headers: { 'Content-Type': 'application/json' } }
      );
    }

    throw new Error(`Unknown decision: ${decision}`);

  } catch (error) {
    console.error('❌ Error in assess-payment-risk:', error);
    return new Response(
      JSON.stringify({
        error: error instanceof Error ? error.message : 'Unknown error',
        success: false,
      }),
      {
        headers: { 'Content-Type': 'application/json' },
        status: 500,
      }
    );
  }
});

// =====================================================
// FONCTIONS UTILITAIRES
// =====================================================

async function logFraudSignal(
  supabase: any,
  transactionId: string,
  signalType: string,
  severity: number,
  description: string,
  details: any = {}
) {
  await supabase.from('payment_fraud_signals').insert({
    transaction_id: transactionId,
    signal_type: signalType,
    severity,
    description,
    details,
  });
}

function createBlockedResponse(reason: string) {
  return new Response(
    JSON.stringify({
      success: false,
      decision: 'BLOCKED',
      reason,
    }),
    {
      headers: { 'Content-Type': 'application/json' },
      status: 403,
    }
  );
}
