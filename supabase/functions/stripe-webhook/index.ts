/**
 * EDGE FUNCTION: stripe-webhook
 * Traiter les webhooks Stripe (payment_intent.succeeded, payment_intent.payment_failed, etc.)
 * Support: POS, Dépôts, Taxi, Livraison
 * 224SOLUTIONS
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import Stripe from 'https://esm.sh/stripe@14.10.0?target=deno';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'stripe-signature, content-type',
};

const logStep = (step: string, details?: Record<string, unknown>) => {
  const detailsStr = details ? ` - ${JSON.stringify(details)}` : "";
  console.log(`[STRIPE-WEBHOOK] ${step}${detailsStr}`);
};

const isUuid = (value?: string | null) =>
  !!value && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);

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

    // Initialize Stripe
    const stripeSecretKey = Deno.env.get('STRIPE_SECRET_KEY');
    const stripeWebhookSecret = Deno.env.get('STRIPE_WEBHOOK_SECRET');
    
    if (!stripeSecretKey || !stripeWebhookSecret) {
      logStep('ERROR', { message: 'Missing STRIPE_SECRET_KEY or STRIPE_WEBHOOK_SECRET' });
      return new Response(
        JSON.stringify({ error: 'Stripe configuration incomplete' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const stripe = new Stripe(stripeSecretKey, {
      apiVersion: '2023-10-16',
      httpClient: Stripe.createFetchHttpClient(),
    });

    // Get raw body for signature verification
    const body = await req.text();
    const signature = req.headers.get('stripe-signature');

    // SECURITY: Reject requests without signature — no unsigned webhooks allowed
    if (!signature) {
      logStep('ERROR', { message: 'Missing stripe-signature header' });
      return new Response(
        JSON.stringify({ error: 'Missing stripe-signature header' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    let event: Stripe.Event;

    try {
      event = await stripe.webhooks.constructEventAsync(
        body,
        signature,
        stripeWebhookSecret
      );
      logStep('Webhook signature verified', { eventType: event.type });
    } catch (err) {
      logStep('Webhook signature verification failed', { error: String(err) });
      return new Response(
        JSON.stringify({ error: 'Invalid signature' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Process event based on type
    logStep('Processing webhook event', { type: event.type });

    switch (event.type) {
      case 'payment_intent.succeeded': {
        const paymentIntent = event.data.object as Stripe.PaymentIntent;
        logStep('Payment succeeded', { 
          id: paymentIntent.id,
          metadata: paymentIntent.metadata 
        });
        
        const source = paymentIntent.metadata?.source;
        
        // Récupérer charge pour détails paiement
        let chargeId = null;
        let last4 = null;
        let cardBrand = null;
        let threeDsStatus = null;

        if (paymentIntent.latest_charge) {
          try {
            const charge = await stripe.charges.retrieve(paymentIntent.latest_charge as string);
            chargeId = charge.id;
            
            if (charge.payment_method_details?.card) {
              last4 = charge.payment_method_details.card.last4;
              cardBrand = charge.payment_method_details.card.brand;
              threeDsStatus = charge.payment_method_details.card.three_d_secure?.authentication_flow || null;
            }
          } catch (chargeErr) {
            logStep('Error fetching charge', { error: String(chargeErr) });
          }
        }

        // Traiter selon le type de source
        if (source === 'taxi' || paymentIntent.metadata?.ride_id) {
          // Paiement taxi-moto
          logStep('Processing taxi payment');
          
          const { error: taxiError } = await supabase.rpc('process_taxi_card_payment', {
            p_stripe_payment_intent_id: paymentIntent.id
          });

          if (taxiError) {
            logStep('Error processing taxi payment', { error: taxiError.message });
          } else {
            logStep('Taxi payment processed successfully');
          }
          
        } else if (source === 'wallet_deposit' || paymentIntent.metadata?.type === 'deposit') {
          // Dépôt wallet
          logStep('Processing wallet deposit');
          
          const { data: transaction } = await supabase
            .from('stripe_transactions')
            .select('id')
            .eq('stripe_payment_intent_id', paymentIntent.id)
            .single();

          if (transaction) {
            await supabase
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

            const { error: depositError } = await supabase.rpc('process_deposit_payment', {
              p_transaction_id: transaction.id
            });

            if (depositError) {
              logStep('Error processing deposit', { error: depositError.message });
            } else {
              logStep('Deposit processed successfully');
            }
          }

        } else if (source === 'restaurant') {
          // =========================================================
          // 🍽️ PAIEMENT RESTAURANT
          // =========================================================
          logStep('Processing restaurant payment');

          const { data: transaction, error: fetchError } = await supabase
            .from('stripe_transactions')
            .select('*')
            .eq('stripe_payment_intent_id', paymentIntent.id)
            .single();

          if (fetchError || !transaction) {
            logStep('Restaurant transaction not found', { paymentIntentId: paymentIntent.id });
            break;
          }

          // Mettre à jour la transaction stripe
          await supabase
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

          // Créditer le wallet du restaurateur
          try {
            const { data: walletResult, error: walletError } = await supabase
              .rpc('force_credit_seller_wallet', {
                p_transaction_id: transaction.id
              });

            if (walletError) {
              logStep('❌ Error crediting restaurant wallet', { error: walletError.message });
              const { error: fallbackError } = await supabase.rpc('process_successful_payment', {
                p_transaction_id: transaction.id
              });
              if (fallbackError) {
                logStep('❌ Fallback also failed', { error: fallbackError.message });
              } else {
                logStep('✅ Restaurant wallet credited via fallback');
              }
            } else {
              logStep('✅ Restaurant wallet credited', { result: walletResult });
            }
          } catch (walletErr) {
            logStep('❌ Exception crediting restaurant wallet', { error: String(walletErr) });
          }

          // Mettre à jour restaurant_orders
          const orderId = transaction.order_id || paymentIntent.metadata?.order_id;
          if (orderId) {
            const { error: orderUpdateError } = await supabase
              .from('restaurant_orders')
              .update({
                payment_status: 'paid',
                status: 'confirmed',
                updated_at: new Date().toISOString(),
              })
              .eq('id', orderId);

            if (orderUpdateError) {
              logStep('⚠️ Error updating restaurant_orders', { error: orderUpdateError.message });
              // Fallback: essayer la table orders classique
              await supabase
                .from('orders')
                .update({
                  payment_status: 'paid',
                  status: 'confirmed',
                  updated_at: new Date().toISOString(),
                })
                .eq('id', orderId);
            } else {
              logStep('✅ Restaurant order updated to paid', { orderId });
            }
          }

        } else if (source === 'delivery') {
          // =========================================================
          // 🚚 PAIEMENT LIVRAISON
          // =========================================================
          logStep('Processing delivery payment');

          const { data: transaction } = await supabase
            .from('stripe_transactions')
            .select('*')
            .eq('stripe_payment_intent_id', paymentIntent.id)
            .single();

          if (transaction) {
            await supabase
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

            // Créditer le wallet du livreur
            try {
              const { error: walletError } = await supabase.rpc('force_credit_seller_wallet', {
                p_transaction_id: transaction.id
              });
              if (walletError) {
                logStep('⚠️ Delivery wallet credit error', { error: walletError.message });
              } else {
                logStep('✅ Delivery wallet credited');
              }
            } catch (e) {
              logStep('❌ Exception crediting delivery wallet', { error: String(e) });
            }
          }

          // Mettre à jour la livraison
          const deliveryId = paymentIntent.metadata?.delivery_id;
          if (deliveryId) {
            await supabase
              .from('deliveries')
              .update({
                payment_status: 'paid',
                updated_at: new Date().toISOString(),
              })
              .eq('id', deliveryId);
            logStep('✅ Delivery updated to paid', { deliveryId });
          }
          
        } else if (source === 'marketplace_escrow') {
          // =========================================================
          // 🛒🔒 PAIEMENT MARKETPLACE ESCROW (fonds bloqués)
          // =========================================================
          logStep('Processing marketplace escrow payment (requires_capture)');

          const { data: transaction, error: fetchError } = await supabase
            .from('stripe_transactions')
            .select('*')
            .eq('stripe_payment_intent_id', paymentIntent.id)
            .single();

          if (fetchError || !transaction) {
            logStep('Marketplace escrow transaction not found', { paymentIntentId: paymentIntent.id });
            break;
          }

          // Mettre à jour la transaction — statut HELD (pas SUCCEEDED, fonds pas encore capturés)
          await supabase
            .from('stripe_transactions')
            .update({
              status: 'HELD',
              stripe_charge_id: chargeId,
              last4: last4,
              card_brand: cardBrand,
              three_ds_status: threeDsStatus,
              paid_at: new Date().toISOString(),
              updated_at: new Date().toISOString(),
            })
            .eq('id', transaction.id);

          // Mettre à jour les escrow_transactions liés
          await supabase
            .from('escrow_transactions')
            .update({ status: 'held', updated_at: new Date().toISOString() })
            .eq('stripe_payment_intent_id', paymentIntent.id)
            .in('status', ['pending']);

          logStep('✅ Marketplace escrow: transaction HELD, escrows updated to held');
          // ⚠️ PAS de crédit vendeur ici — les fonds seront libérés via confirm-delivery

        } else if (source === 'marketplace') {
          // =========================================================
          // 🛒 PAIEMENT MARKETPLACE DIRECT (legacy, capture immédiate)
          // =========================================================
          logStep('Processing marketplace payment (direct)');

          const { data: transaction, error: fetchError } = await supabase
            .from('stripe_transactions')
            .select('*')
            .eq('stripe_payment_intent_id', paymentIntent.id)
            .single();

          if (fetchError || !transaction) {
            logStep('Marketplace transaction not found', { paymentIntentId: paymentIntent.id });
            break;
          }

          await supabase
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

          logStep('✅ Marketplace transaction updated to SUCCEEDED');

          if (transaction.commission_amount > 0) {
            try {
              await supabase.rpc('record_pdg_revenue', {
                p_source_type: 'frais_achat_marketplace',
                p_amount: transaction.commission_amount,
                p_percentage: transaction.commission_rate || 5,
                p_transaction_id: transaction.id,
                p_user_id: transaction.buyer_id,
                p_metadata: {
                  payment_intent_id: paymentIntent.id,
                  product_amount: transaction.seller_net_amount,
                  total_amount: transaction.amount,
                }
              });
              logStep('✅ PDG revenue recorded for marketplace');
            } catch (revenueErr) {
              logStep('⚠️ Error recording PDG revenue', { error: String(revenueErr) });
            }
          }

          try {
            const commissionTransactionId = isUuid(transaction.order_id) ? transaction.order_id : transaction.id;
            const { error: agentCommissionError } = await supabase.rpc('credit_agent_commission', {
              p_user_id: transaction.buyer_id,
              p_amount: transaction.amount,
              p_source_type: 'achat_produit',
              p_transaction_id: commissionTransactionId,
              p_metadata: {
                currency: transaction.currency || 'GNF',
                order_id: transaction.order_id,
                stripe_transaction_id: transaction.id,
                source: 'stripe-webhook-edge',
              },
            });

            if (agentCommissionError) {
              logStep('Agent commission error', { error: agentCommissionError.message });
            } else {
              logStep('Agent commission processed for marketplace payment');
            }
          } catch (commissionErr) {
            logStep('Agent commission exception', { error: String(commissionErr) });
          }

        } else {
          // Paiement POS standard
          logStep('Processing POS payment');
          
          const { data: transaction, error: fetchError } = await supabase
            .from('stripe_transactions')
            .select('*')
            .eq('stripe_payment_intent_id', paymentIntent.id)
            .single();

          if (fetchError || !transaction) {
            logStep('Transaction not found', { paymentIntentId: paymentIntent.id });
            break;
          }

          await supabase
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

          // Créer commande si manquante
          let orderId = transaction.order_id;
          
          if (!orderId && transaction.product_id) {
            logStep('📦 Creating order from payment...');
            try {
              const { data: orderResult, error: orderError } = await supabase
                .rpc('create_order_from_payment', {
                  p_transaction_id: transaction.id
                });
              if (orderError) {
                logStep('⚠️ Error creating order', { error: orderError.message });
              } else if (orderResult?.success) {
                orderId = orderResult.order_id;
                logStep('✅ Order created', { orderId, orderNumber: orderResult.order_number });
              }
            } catch (orderErr) {
              logStep('⚠️ Exception creating order', { error: String(orderErr) });
            }
          }

          // Créditer wallet vendeur
          logStep('💰 Crediting seller wallet...');
          try {
            const { data: walletResult, error: walletError } = await supabase
              .rpc('force_credit_seller_wallet', {
                p_transaction_id: transaction.id
              });
            if (walletError) {
              logStep('❌ Error crediting wallet', { error: walletError.message });
              const { error: processError } = await supabase.rpc('process_successful_payment', {
                p_transaction_id: transaction.id
              });
              if (processError) {
                logStep('❌ Error in fallback wallet credit', { error: processError.message });
              } else {
                logStep('✅ Wallet credited via fallback');
              }
            } else if (walletResult?.success) {
              logStep('✅ Wallet credited', {
                walletId: walletResult.wallet_id,
                amount: walletResult.amount_credited,
                balanceBefore: walletResult.balance_before,
                balanceAfter: walletResult.balance_after
              });
            }
          } catch (walletErr) {
            logStep('❌ Exception crediting wallet', { error: String(walletErr) });
          }

          // Mettre à jour la commande
          if (orderId) {
            await supabase
              .from('orders')
              .update({
                payment_status: 'paid',
                status: 'confirmed',
                updated_at: new Date().toISOString(),
              })
              .eq('id', orderId);
            logStep('✅ Order updated', { orderId });
          }

          try {
            const commissionTransactionId = isUuid(orderId) ? orderId : transaction.id;
            const { error: agentCommissionError } = await supabase.rpc('credit_agent_commission', {
              p_user_id: transaction.buyer_id,
              p_amount: transaction.amount,
              p_source_type: 'achat_produit',
              p_transaction_id: commissionTransactionId,
              p_metadata: {
                currency: transaction.currency || 'GNF',
                order_id: orderId || transaction.order_id,
                stripe_transaction_id: transaction.id,
                source: 'stripe-webhook-edge',
              },
            });

            if (agentCommissionError) {
              logStep('Agent commission error', { error: agentCommissionError.message });
            } else {
              logStep('Agent commission processed for payment');
            }
          } catch (commissionErr) {
            logStep('Agent commission exception', { error: String(commissionErr) });
          }
        }

        break;
      }

      case 'payment_intent.payment_failed': {
        const paymentIntent = event.data.object as Stripe.PaymentIntent;
        logStep('Payment failed', { id: paymentIntent.id });

        const error = paymentIntent.last_payment_error;

        // Mettre à jour transaction
        await supabase
          .from('stripe_transactions')
          .update({
            status: 'FAILED',
            error_code: error?.code || 'unknown',
            error_message: error?.message || 'Payment failed',
            updated_at: new Date().toISOString(),
          })
          .eq('stripe_payment_intent_id', paymentIntent.id);

        // Mettre à jour taxi_transactions si c'est un paiement taxi
        if (paymentIntent.metadata?.ride_id) {
          await supabase
            .from('taxi_transactions')
            .update({
              status: 'failed',
              metadata: { error: error?.message }
            })
            .eq('provider_tx_id', paymentIntent.id);
        }

        break;
      }

      case 'payment_intent.canceled': {
        const paymentIntent = event.data.object as Stripe.PaymentIntent;
        logStep('Payment canceled', { id: paymentIntent.id });

        await supabase
          .from('stripe_transactions')
          .update({
            status: 'CANCELED',
            updated_at: new Date().toISOString(),
          })
          .eq('stripe_payment_intent_id', paymentIntent.id);

        break;
      }

      case 'payment_intent.requires_action': {
        const paymentIntent = event.data.object as Stripe.PaymentIntent;
        logStep('Payment requires 3D Secure', { id: paymentIntent.id });

        await supabase
          .from('stripe_transactions')
          .update({
            requires_3ds: true,
            updated_at: new Date().toISOString(),
          })
          .eq('stripe_payment_intent_id', paymentIntent.id);

        break;
      }

      case 'charge.refunded': {
        const charge = event.data.object as Stripe.Charge;
        logStep('Charge refunded', { id: charge.id });

        await supabase
          .from('stripe_transactions')
          .update({
            status: 'REFUNDED',
            refunded_at: new Date().toISOString(),
            updated_at: new Date().toISOString(),
          })
          .eq('stripe_charge_id', charge.id);

        break;
      }

      case 'charge.dispute.created': {
        const dispute = event.data.object as Stripe.Dispute;
        logStep('Dispute created', { id: dispute.id });

        await supabase
          .from('stripe_transactions')
          .update({
            status: 'DISPUTED',
            updated_at: new Date().toISOString(),
          })
          .eq('stripe_charge_id', dispute.charge as string);

        break;
      }

      default:
        logStep('Unhandled event type', { type: event.type });
    }

    return new Response(
      JSON.stringify({ received: true, event_type: event.type }),
      { 
        status: 200, 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
      }
    );

  } catch (error) {
    logStep('Error in stripe-webhook', { error: String(error) });
    const message = error instanceof Error ? error.message : 'Internal server error';
    return new Response(
      JSON.stringify({ 
        error: 'Webhook processing failed', 
        details: message 
      }),
      { 
        status: 500, 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
      }
    );
  }
});
