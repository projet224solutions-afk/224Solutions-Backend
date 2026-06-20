/**
 * 🔐 EDGE FUNCTION: PROCESSUS DE PAIEMENT TAXI-MOTO SÉCURISÉ
 * Gère les paiements multi-canaux avec signature HMAC obligatoire
 * Règles de sécurité financières 224Solutions
 */

import { serve } from 'https://deno.land/std@0.190.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { crypto } from "https://deno.land/std@0.190.0/crypto/mod.ts";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const TRANSACTION_SECRET = Deno.env.get("TRANSACTION_SECRET_KEY");
if (!TRANSACTION_SECRET) throw new Error("CRITICAL: TRANSACTION_SECRET_KEY not configured");

// 🔐 Génère une signature HMAC-SHA256
async function generateSignature(transactionId: string, amount: number): Promise<string> {
  const encoder = new TextEncoder();
  const data = encoder.encode(`${transactionId}${amount}`);
  const keyData = encoder.encode(TRANSACTION_SECRET);
  
  const key = await crypto.subtle.importKey(
    "raw", keyData, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]
  );
  
  const signature = await crypto.subtle.sign("HMAC", key, data);
  return Array.from(new Uint8Array(signature)).map(b => b.toString(16).padStart(2, "0")).join("");
}

// 🔐 Log d'audit
async function logFinancialAudit(supabase: any, userId: string, action: string, data: any, isSuspicious = false) {
  try {
    await supabase.from("financial_audit_logs").insert({
      user_id: userId,
      action_type: action,
      description: `Taxi payment: ${action}`,
      request_data: data,
      is_suspicious: isSuspicious
    });
  } catch (e) { console.error("[Audit] Log failed:", e); }
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders })
  }

  try {
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    const { tripId, paymentMethod, amount, customerId, driverId, idempotencyKey } = await req.json()

    console.log(`[Taxi Payment] Processing: ${paymentMethod} - ${amount} GNF - Trip: ${tripId}`)

    // Vérifier doublon avec idempotency key
    if (idempotencyKey) {
      const { data: existing } = await supabase
        .from('taxi_transactions')
        .select('*')
        .eq('idempotency_key', idempotencyKey)
        .single()

      if (existing) {
        console.log('[Taxi Payment] Duplicate detected, returning existing transaction')
        return new Response(
          JSON.stringify({ success: true, transaction: existing, duplicate: true }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        )
      }
    }

    // 🔐 Générer ID et signature sécurisée
    const transactionId = `TAXI-${Date.now()}-${Math.random().toString(36).substr(2, 8).toUpperCase()}`;
    const signature = await generateSignature(transactionId, amount);

    // 🔐 Créer transaction sécurisée immutable
    const { data: transaction, error: txError } = await supabase
      .from('taxi_transactions')
      .insert({
        id: transactionId,
        ride_id: tripId,
        customer_id: customerId,
        driver_id: driverId,
        amount,
        payment_method: paymentMethod,
        status: 'pending',
        idempotency_key: idempotencyKey,
        currency: 'GNF',
        signature: signature // 🔐 Signature HMAC stockée
      })
      .select()
      .single()

    if (txError) throw txError

    // 🔐 Log audit création
    await logFinancialAudit(supabase, customerId, 'taxi_transaction_created', {
      transactionId, amount, tripId, paymentMethod, signature: signature.substring(0, 16) + '...'
    });

    let paymentResult

    // Traiter selon le mode de paiement
    switch (paymentMethod) {
      case 'wallet': {
        paymentResult = await processWalletPayment(supabase, customerId, driverId, amount, tripId)
        break
      }
      
      case 'card': {
        const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')
        if (!stripeKey) throw new Error('Stripe not configured')
        paymentResult = await processCardPayment(stripeKey, amount, customerId, tripId)
        break
      }
      
      case 'orange_money': {
        paymentResult = await processOrangeMoneyPayment(customerId, amount, tripId)
        break
      }
      
      case 'mtn_money': {
        paymentResult = await processMTNMoneyPayment(customerId, amount, tripId)
        break
      }
      
      case 'cash': {
        paymentResult = { status: 'pending', message: 'Cash payment pending driver confirmation' }
        break
      }
      
      default:
        throw new Error(`Unsupported payment method: ${paymentMethod}`)
    }

    // Mettre à jour la transaction
    const finalStatus = paymentResult.status === 'completed' ? 'completed' : paymentResult.status
    
    const { error: updateError } = await supabase
      .from('taxi_transactions')
      .update({
        status: finalStatus,
        external_ref: paymentResult.ref,
        metadata: paymentResult.metadata || {},
        completed_at: finalStatus === 'completed' ? new Date().toISOString() : null
      })
      .eq('id', transaction.id)

    if (updateError) throw updateError

    // Si paiement réussi, mettre à jour la course
    if (finalStatus === 'completed') {
      await supabase
        .from('taxi_trips')
        .update({
          payment_status: 'paid',
          payment_method: paymentMethod
        })
        .eq('id', tripId)

      // Notifier le conducteur
      await supabase.rpc('create_taxi_notification', {
        p_user_id: (await supabase.from('taxi_drivers').select('user_id').eq('id', driverId).single()).data?.user_id,
        p_type: 'payment_received',
        p_title: 'Paiement reçu',
        p_body: `Paiement de ${amount} GNF reçu pour la course`,
        p_data: { tripId, amount, method: paymentMethod },
        p_ride_id: tripId
      })
    }

    console.log(`[Taxi Payment] Success: ${finalStatus}`)

    return new Response(
      JSON.stringify({
        success: true,
        transaction: { ...transaction, status: finalStatus },
        payment: paymentResult
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )

  } catch (error) {
    console.error('[Taxi Payment] Error:', error)
    return new Response(
      JSON.stringify({ error: error instanceof Error ? error.message : 'Unknown error' }),
      { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  }
})

/**
 * 🔐 Traitement Wallet 224Solutions avec signature HMAC
 */
async function processWalletPayment(supabase: any, customerId: string, driverId: string, amount: number, tripId: string) {
  const transactionId = `TAXI-WALLET-${Date.now()}`;
  
  // 🔐 Générer signature pour cette opération
  const signature = await generateSignature(transactionId, amount);
  
  // Vérifier le solde
  const { data: wallet } = await supabase
    .from('wallets')
    .select('id, balance')
    .eq('user_id', customerId)
    .eq('currency', 'GNF')
    .single()

  if (!wallet || wallet.balance < amount) {
    await logFinancialAudit(supabase, customerId, 'taxi_payment_failed', {
      reason: 'insufficient_balance', tripId, amount, available: wallet?.balance || 0
    }, true);
    return { status: 'failed', message: 'Insufficient balance' }
  }

  // 🔐 Créer enregistrement sécurisé AVANT modification
  const { error: secureInsertError } = await supabase
    .from('secure_transactions')
    .insert({
      id: transactionId,
      user_id: customerId,
      requested_amount: amount,
      fee_amount: 0,
      total_amount: amount,
      net_amount: amount,
      signature: signature,
      status: 'pending',
      transaction_type: 'taxi_debit',
      metadata: { tripId, driverId }
    });

  if (secureInsertError) {
    console.error('[Taxi] Secure transaction insert failed:', secureInsertError);
    return { status: 'failed', message: 'Transaction security error' };
  }

  // 🔐 Débiter le client avec vérification optimiste
  const newBalance = wallet.balance - amount;
  const { data: debitResult, error: debitError } = await supabase
    .from('wallets')
    .update({ balance: newBalance, updated_at: new Date().toISOString() })
    .eq('user_id', customerId)
    .eq('balance', wallet.balance) // 🔐 Verrouillage optimiste
    .select('balance')
    .single();

  if (debitError || !debitResult) {
    // 🔐 Marquer transaction comme échouée
    await supabase.from('secure_transactions').update({ status: 'failed' }).eq('id', transactionId);
    await logFinancialAudit(supabase, customerId, 'taxi_debit_failed', {
      reason: 'concurrent_modification', tripId, amount
    }, true);
    return { status: 'failed', message: 'Balance modified during transaction' };
  }

  // Calculer les parts (85% conducteur, 15% plateforme)
  const driverShare = Math.round(amount * 0.85)
  const platformFee = amount - driverShare

  // Créditer le conducteur
  const { data: driverData } = await supabase
    .from('taxi_drivers')
    .select('user_id')
    .eq('id', driverId)
    .single()

  if (driverData) {
    await supabase.rpc('credit_wallet', {
      receiver_user_id: driverData.user_id,
      credit_amount: driverShare
    })
  }

  // 🔐 Marquer transaction sécurisée comme complétée
  await supabase.from('secure_transactions')
    .update({ status: 'completed', completed_at: new Date().toISOString() })
    .eq('id', transactionId);

  // 🔐 Log audit succès
  await logFinancialAudit(supabase, customerId, 'taxi_payment_completed', {
    transactionId, tripId, amount, driverShare, platformFee, newBalance
  });

  return {
    status: 'completed',
    ref: transactionId,
    metadata: { driverShare, platformFee, signature: signature.substring(0, 16) + '...' }
  }
}

/**
 * Traitement Carte Bancaire (Stripe)
 */
async function processCardPayment(stripeKey: string, amount: number, customerId: string, tripId: string) {
  const amountInCents = Math.round(amount) // GNF n'a pas de centimes

  const response = await fetch('https://api.stripe.com/v1/payment_intents', {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${stripeKey}`,
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: new URLSearchParams({
      amount: amountInCents.toString(),
      currency: 'gnf',
      'metadata[customer_id]': customerId,
      'metadata[trip_id]': tripId,
    }),
  })

  const paymentIntent = await response.json()

  if (!response.ok) {
    throw new Error(`Stripe error: ${paymentIntent.error?.message || 'Unknown error'}`)
  }

  return {
    status: 'processing',
    ref: paymentIntent.id,
    metadata: {
      client_secret: paymentIntent.client_secret,
      status: paymentIntent.status
    }
  }
}

/**
 * Traitement Orange Money
 */
async function processOrangeMoneyPayment(customerId: string, amount: number, tripId: string) {
  const orangeApiKey = Deno.env.get('ORANGE_MONEY_API_KEY')
  const orangeUrl = Deno.env.get('ORANGE_MONEY_API_URL')

  if (!orangeApiKey || !orangeUrl) {
    return { status: 'failed', message: 'Orange Money not configured' }
  }

  // TODO: Implémenter l'API Orange Money réelle
  // Pour l'instant, retourner un statut processing
  console.log('[Orange Money] Payment initiated:', { customerId, amount, tripId })

  return {
    status: 'processing',
    ref: `OM-${Date.now()}`,
    metadata: { provider: 'orange_money' }
  }
}

/**
 * Traitement MTN Money
 */
async function processMTNMoneyPayment(customerId: string, amount: number, tripId: string) {
  const mtnApiKey = Deno.env.get('MTN_MONEY_API_KEY')
  const mtnUrl = Deno.env.get('MTN_MONEY_API_URL')

  if (!mtnApiKey || !mtnUrl) {
    return { status: 'failed', message: 'MTN Money not configured' }
  }

  // TODO: Implémenter l'API MTN Money réelle
  console.log('[MTN Money] Payment initiated:', { customerId, amount, tripId })

  return {
    status: 'processing',
    ref: `MTN-${Date.now()}`,
    metadata: { provider: 'mtn_money' }
  }
}
