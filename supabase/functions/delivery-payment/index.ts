/**
 * EDGE FUNCTION - PAIEMENT LIVRAISON AVEC ESCROW
 * Commission: 3%
 * Auto-release: 1 jour après livraison
 * Support: wallet, card, mobile_money, cash
 */

// Using native Deno.serve() API
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

interface DeliveryPaymentRequest {
  delivery_id: string;
  customer_id: string;
  driver_id: string;
  amount: number;
  payment_method: 'wallet' | 'card' | 'mobile_money' | 'cash';
  payment_method_id?: string; // Pour Stripe
  phone_number?: string; // Pour Orange Money
  provider?: 'orange' | 'mtn' | 'moov'; // Pour Mobile Money
}

Deno.serve(async (req) => {
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
      delivery_id,
      customer_id,
      driver_id,
      amount,
      payment_method,
      payment_method_id,
      phone_number,
      provider
    }: DeliveryPaymentRequest = await req.json()

    console.log('[DeliveryPayment] Processing payment:', {
      delivery_id,
      customer_id,
      driver_id,
      amount,
      payment_method
    })

    // 1. Vérifier que la livraison existe
    const { data: delivery, error: deliveryError } = await supabase
      .from('deliveries')
      .select('*')
      .eq('id', delivery_id)
      .single()

    if (deliveryError || !delivery) {
      throw new Error('Livraison introuvable')
    }

    // 2. Vérifier que le livreur existe
    const { data: driver, error: driverError } = await supabase
      .from('profiles')
      .select('id, role')
      .eq('id', driver_id)
      .eq('role', 'livreur')
      .single()

    if (driverError || !driver) {
      throw new Error('Livreur introuvable')
    }

    // 3. CRÉER L'ESCROW (fonds bloqués jusqu'à livraison)
    let escrowId: string | null = null;
    let stripePaymentIntentId: string | null = null;

    if (payment_method === 'wallet') {
      // Vérifier le solde wallet
      const { data: wallet } = await supabase
        .from('wallets')
        .select('balance')
        .eq('user_id', customer_id)
        .single()

      if (!wallet || wallet.balance < amount) {
        throw new Error('Solde wallet insuffisant')
      }

      // Débiter le wallet et créer l'escrow
      const { data: escrowData, error: escrowError } = await supabase.rpc('create_escrow', {
        p_buyer_id: customer_id,
        p_seller_id: driver_id,
        p_order_id: delivery_id,
        p_amount: amount,
        p_currency: 'GNF',
        p_transaction_type: 'delivery',
        p_commission_percent: 3.0,
        p_auto_release_days: 1,
        p_metadata: {
          delivery_id: delivery_id,
          pickup_address: delivery.pickup_address,
          delivery_address: delivery.delivery_address,
          payment_method: 'wallet'
        }
      })

      if (escrowError) {
        console.error('[DeliveryPayment] Escrow creation error:', escrowError)
        throw new Error('Échec création escrow')
      }

      escrowId = escrowData
      console.log('[DeliveryPayment] Escrow created:', escrowId)

    } else if (payment_method === 'card') {
      // Paiement Stripe - créer Payment Intent pour confirmation côté client
      const stripe = (await import('https://esm.sh/stripe@13.6.0')).default(
        Deno.env.get('STRIPE_SECRET_KEY') ?? ''
      )

      // Commission livraison (3%)
      const commissionAmount = Math.round(amount * 0.03)
      const totalAmount = amount + commissionAmount

      const paymentIntent = await stripe.paymentIntents.create({
        amount: Math.round(totalAmount),
        currency: 'gnf',
        automatic_payment_methods: { enabled: true },
        description: `Livraison ${delivery_id}`,
        metadata: {
          delivery_id: delivery_id,
          customer_id: customer_id,
          driver_id: driver_id,
          type: 'delivery',
          commission_amount: commissionAmount.toString(),
          driver_share: (amount - commissionAmount).toString(),
          source: 'delivery',
        },
      })

      stripePaymentIntentId = paymentIntent.id

      // Créer l'escrow (sera funded quand le paiement sera confirmé côté client)
      const { data: escrowData, error: escrowError } = await supabase.rpc('create_escrow', {
        p_buyer_id: customer_id,
        p_seller_id: driver_id,
        p_order_id: delivery_id,
        p_amount: amount,
        p_currency: 'GNF',
        p_transaction_type: 'delivery',
        p_commission_percent: 3.0,
        p_auto_release_days: 1,
        p_metadata: {
          delivery_id: delivery_id,
          stripe_payment_intent_id: stripePaymentIntentId,
          payment_method: 'card',
          status: 'awaiting_confirmation'
        }
      })

      if (escrowError) throw new Error('Échec création escrow')
      escrowId = escrowData

      // Retourner le client_secret pour confirmation côté client
      return new Response(
        JSON.stringify({
          success: true,
          escrow_id: escrowId,
          client_secret: paymentIntent.client_secret,
          payment_intent_id: paymentIntent.id,
          amount: totalAmount,
          commission: commissionAmount,
          requires_confirmation: true,
          message: 'Confirmez le paiement côté client'
        }),
        {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          status: 200,
        }
      )

    } else if (payment_method === 'mobile_money') {
      throw new Error('Mobile money via Djomy est définitivement désactivé')

    } else if (payment_method === 'cash') {
      // Paiement cash - Escrow créé mais statut "pending_cash"
      const { data: escrowData, error: escrowError } = await supabase.rpc('create_escrow', {
        p_buyer_id: customer_id,
        p_seller_id: driver_id,
        p_order_id: delivery_id,
        p_amount: amount,
        p_currency: 'GNF',
        p_transaction_type: 'delivery',
        p_commission_percent: 3.0,
        p_auto_release_days: 0, // Cash = release immédiat après confirmation
        p_metadata: {
          delivery_id: delivery_id,
          payment_method: 'cash'
        }
      })

      if (escrowError) throw new Error('Échec création escrow')
      escrowId = escrowData
    }

    // 4. Mettre à jour la livraison
    const { error: updateError } = await supabase
      .from('deliveries')
      .update({
        status: 'in_transit',
        payment_status: 'paid',
        escrow_id: escrowId,
        updated_at: new Date().toISOString()
      })
      .eq('id', delivery_id)

    if (updateError) {
      console.error('[DeliveryPayment] Update delivery error:', updateError)
    }

    console.log('[DeliveryPayment] Payment successful:', {
      escrow_id: escrowId,
      stripe_payment_intent_id: stripePaymentIntentId
    })

    return new Response(
      JSON.stringify({
        success: true,
        escrow_id: escrowId,
        stripe_payment_intent_id: stripePaymentIntentId,
        message: 'Paiement effectué avec succès'
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200,
      }
    )

  } catch (error) {
    console.error('[DeliveryPayment] Error:', error)
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
