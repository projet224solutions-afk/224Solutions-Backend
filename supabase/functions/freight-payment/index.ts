/**
 * EDGE FUNCTION - PAIEMENT TRANSITAIRE (Import/Export) AVEC ESCROW
 * Commission: 2%
 * Auto-release: 30 jours (dédouanement)
 * Support: wallet, card, bank_transfer
 */

import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

interface FreightPaymentRequest {
  freight_order_id: string;
  client_id: string;
  freight_agent_id: string;
  amount: number;
  payment_method: 'wallet' | 'card' | 'bank_transfer';
  payment_method_id?: string; // Pour Stripe
  bank_transfer_proof?: string; // Preuve de virement
}

serve(async (req) => {
  // Handle CORS
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    const {
      freight_order_id,
      client_id,
      freight_agent_id,
      amount,
      payment_method,
      payment_method_id,
      bank_transfer_proof
    }: FreightPaymentRequest = await req.json()

    console.log('[FreightPayment] Processing payment:', {
      freight_order_id,
      client_id,
      freight_agent_id,
      amount,
      payment_method
    })

    // 1. Vérifier que la commande freight existe
    const { data: freightOrder, error: orderError } = await supabase
      .from('freight_orders')
      .select('*')
      .eq('id', freight_order_id)
      .single()

    if (orderError || !freightOrder) {
      throw new Error('Commande transitaire introuvable')
    }

    // 2. Vérifier que le transitaire existe
    const { data: agent, error: agentError } = await supabase
      .from('profiles')
      .select('id, role')
      .eq('id', freight_agent_id)
      .eq('role', 'transitaire')
      .single()

    if (agentError || !agent) {
      throw new Error('Transitaire introuvable')
    }

    // 3. CRÉER L'ESCROW (fonds bloqués 30 jours)
    let escrowId: string | null = null;
    let stripePaymentIntentId: string | null = null;

    if (payment_method === 'wallet') {
      // Vérifier le solde wallet
      const { data: wallet } = await supabase
        .from('wallets')
        .select('balance')
        .eq('user_id', client_id)
        .single()

      if (!wallet || wallet.balance < amount) {
        throw new Error('Solde wallet insuffisant')
      }

      // Débiter le wallet et créer l'escrow
      const { data: escrowData, error: escrowError } = await supabase.rpc('create_escrow', {
        p_buyer_id: client_id,
        p_seller_id: freight_agent_id,
        p_order_id: freight_order_id,
        p_amount: amount,
        p_currency: 'GNF',
        p_transaction_type: 'freight',
        p_commission_percent: 2.0,
        p_auto_release_days: 30, // 30 jours pour dédouanement
        p_metadata: {
          freight_order_id: freight_order_id,
          origin_country: freightOrder.origin_country,
          destination: freightOrder.destination,
          cargo_description: freightOrder.cargo_description,
          weight_kg: freightOrder.weight_kg,
          service_type: freightOrder.service_type, // 'maritime' | 'aerien'
          payment_method: 'wallet'
        }
      })

      if (escrowError) {
        console.error('[FreightPayment] Escrow creation error:', escrowError)
        throw new Error('Échec création escrow')
      }

      escrowId = escrowData
      console.log('[FreightPayment] Escrow created:', escrowId)

    } else if (payment_method === 'card') {
      // Paiement Stripe avec escrow
      const stripe = (await import('https://esm.sh/stripe@13.6.0')).default(
        Deno.env.get('STRIPE_SECRET_KEY') ?? ''
      )

      const paymentIntent = await stripe.paymentIntents.create({
        amount: Math.round(amount), // Montant en centimes
        currency: 'gnf',
        payment_method: payment_method_id,
        confirm: true,
        description: `Transitaire ${freight_order_id}`,
        metadata: {
          freight_order_id: freight_order_id,
          client_id: client_id,
          freight_agent_id: freight_agent_id,
          type: 'freight'
        },
        return_url: `${Deno.env.get('FRONTEND_URL')}/freight/payment-callback`
      })

      if (paymentIntent.status !== 'succeeded') {
        throw new Error('Paiement Stripe échoué')
      }

      stripePaymentIntentId = paymentIntent.id

      // Créer l'escrow après paiement Stripe réussi
      const { data: escrowData, error: escrowError } = await supabase.rpc('create_escrow', {
        p_buyer_id: client_id,
        p_seller_id: freight_agent_id,
        p_order_id: freight_order_id,
        p_amount: amount,
        p_currency: 'GNF',
        p_transaction_type: 'freight',
        p_commission_percent: 2.0,
        p_auto_release_days: 30,
        p_metadata: {
          freight_order_id: freight_order_id,
          stripe_payment_intent_id: stripePaymentIntentId,
          payment_method: 'card',
          service_type: freightOrder.service_type
        }
      })

      if (escrowError) throw new Error('Échec création escrow')
      escrowId = escrowData

    } else if (payment_method === 'bank_transfer') {
      // Virement bancaire - Escrow créé en statut "pending_verification"
      if (!bank_transfer_proof) {
        throw new Error('Preuve de virement bancaire requise')
      }

      // Créer l'escrow (attendre vérification manuelle)
      const { data: escrowData, error: escrowError } = await supabase.rpc('create_escrow', {
        p_buyer_id: client_id,
        p_seller_id: freight_agent_id,
        p_order_id: freight_order_id,
        p_amount: amount,
        p_currency: 'GNF',
        p_transaction_type: 'freight',
        p_commission_percent: 2.0,
        p_auto_release_days: 30,
        p_metadata: {
          freight_order_id: freight_order_id,
          payment_method: 'bank_transfer',
          bank_transfer_proof: bank_transfer_proof,
          verification_status: 'pending'
        }
      })

      if (escrowError) throw new Error('Échec création escrow')
      escrowId = escrowData

      // Notifier l'admin pour vérification du virement
      await supabase.from('notifications').insert({
        user_id: Deno.env.get('ADMIN_USER_ID') ?? '',
        type: 'bank_transfer_verification',
        title: 'Nouveau virement à vérifier',
        message: `Commande transitaire ${freight_order_id} - ${amount} GNF`,
        metadata: {
          freight_order_id: freight_order_id,
          escrow_id: escrowId,
          bank_transfer_proof: bank_transfer_proof
        }
      })
    }

    // 4. Mettre à jour la commande freight
    const { error: updateError } = await supabase
      .from('freight_orders')
      .update({
        status: payment_method === 'bank_transfer' ? 'pending_payment_verification' : 'in_progress',
        payment_status: 'paid',
        escrow_id: escrowId,
        updated_at: new Date().toISOString()
      })
      .eq('id', freight_order_id)

    if (updateError) {
      console.error('[FreightPayment] Update freight order error:', updateError)
    }

    console.log('[FreightPayment] Payment successful:', {
      escrow_id: escrowId,
      stripe_payment_intent_id: stripePaymentIntentId
    })

    return new Response(
      JSON.stringify({
        success: true,
        escrow_id: escrowId,
        stripe_payment_intent_id: stripePaymentIntentId,
        message: payment_method === 'bank_transfer' 
          ? 'Paiement en attente de vérification (virement bancaire)'
          : 'Paiement effectué avec succès'
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200,
      }
    )

  } catch (error) {
    console.error('[FreightPayment] Error:', error)
    return new Response(
      JSON.stringify({
        success: false,
        error: error instanceof Error ? error.message : 'Unknown error'
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 400,
      }
    )
  }
})
