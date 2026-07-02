/**
 * 🔔 WEBHOOK HANDLERS - Backend Node.js centralisé
 *
 * Webhooks gérés côté Node.js :
 *   - Stripe  : /webhooks/stripe  (signature + idempotency + ordre/escrow/wallet)
 *
 * Migration :
 *   - stripe-webhook  (Edge Function) : partiellement dupliqué ici; Node.js est la version canonique
 */

import { Router, Request, Response } from 'express';
import crypto from 'crypto';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { auditTrail } from '../services/auditTrail.service.js';
import { webhookRateLimit } from '../middlewares/routeRateLimiter.js';
import { creditWallet } from '../services/wallet.service.js';

const router = Router();

// ==================== STRIPE SIGNATURE VERIFICATION ====================

function verifyStripeSignature(payload: string, signature: string, secret: string): boolean {
  try {
    const elements = signature.split(',');
    const timestampElement = elements.find(e => e.startsWith('t='));
    const signatureElement = elements.find(e => e.startsWith('v1='));

    if (!timestampElement || !signatureElement) return false;

    const timestamp = timestampElement.split('=')[1];
    const expectedSig = signatureElement.split('=')[1];

    // Reject events older than 5 minutes (replay protection)
    const age = Math.floor(Date.now() / 1000) - parseInt(timestamp);
    if (age > 300) {
      logger.warn('Stripe webhook: timestamp too old, possible replay');
      return false;
    }

    const signedPayload = `${timestamp}.${payload}`;
    const computedSig = crypto
      .createHmac('sha256', secret)
      .update(signedPayload)
      .digest('hex');

    return crypto.timingSafeEqual(Buffer.from(computedSig), Buffer.from(expectedSig));
  } catch (err: any) {
    logger.error(`Stripe signature verification error: ${err.message}`);
    return false;
  }
}

// ==================== WEBHOOK EVENT JOURNAL ====================

async function journalEvent(
  webhookId: string,
  eventType: string,
  payload: any,
  status: 'received' | 'processing' | 'completed' | 'failed' | 'skipped',
  errorMessage?: string
): Promise<string | null> {
  try {
    const { data, error } = await supabaseAdmin
      .from('webhook_events')
      .upsert({
        webhook_id: webhookId,
        provider: 'stripe',
        event_type: eventType,
        payload,
        processing_status: status,
        processed_at: status === 'completed' || status === 'failed' ? new Date().toISOString() : null,
        error_message: errorMessage || null,
        updated_at: new Date().toISOString(),
      }, { onConflict: 'provider,webhook_id' })
      .select('id')
      .single();

    return data?.id || null;
  } catch (err: any) {
    logger.error(`Webhook journal error: ${err.message}`);
    return null;
  }
}

async function isAlreadyProcessed(webhookId: string): Promise<boolean> {
  const { data } = await supabaseAdmin
    .from('webhook_events')
    .select('processing_status')
    .eq('provider', 'stripe')
    .eq('webhook_id', webhookId)
    .maybeSingle();

  return data?.processing_status === 'completed';
}

// ==================== EVENT HANDLERS ====================

// Zero-decimal currencies that Stripe sends without ×100
const STRIPE_ZERO_DECIMAL_CURRENCIES = new Set([
  'BIF', 'CLP', 'DJF', 'GNF', 'JPY', 'KMF', 'KRW', 'MGA', 'PYG', 'RWF',
  'UGX', 'VND', 'VUV', 'XAF', 'XOF', 'XPF',
]);

function stripeAmountToReal(stripeAmount: number, currency: string): number {
  return STRIPE_ZERO_DECIMAL_CURRENCIES.has(currency.toUpperCase())
    ? stripeAmount
    : stripeAmount / 100;
}

async function handlePaymentIntentSucceeded(event: any): Promise<void> {
  const paymentIntent = event.data.object;
  let orderId = paymentIntent.metadata?.order_id;
  const userId = paymentIntent.metadata?.user_id;

  logger.info(`Webhook: payment_intent.succeeded — PI=${paymentIntent.id}, order=${orderId}`);

  // If no order_id in metadata, try to find the order by payment_intent_id
  // (marketplace-escrow flow creates the order AFTER the PaymentIntent)
  if (!orderId) {
    const { data: matchedOrder } = await supabaseAdmin
      .from('orders')
      .select('id')
      .eq('payment_intent_id', paymentIntent.id)
      .maybeSingle();
    if (matchedOrder) {
      orderId = matchedOrder.id;
      logger.info(`Webhook: resolved order by payment_intent_id — order=${orderId}`);
    }
  }

  if (orderId) {
    // Update order payment status
    await supabaseAdmin
      .from('orders')
      .update({
        payment_status: 'paid',
        payment_intent_id: paymentIntent.id,
        updated_at: new Date().toISOString(),
      })
      .eq('id', orderId);

    // Update escrow to confirmed (try both order_id and stripe_payment_intent_id)
    await supabaseAdmin
      .from('escrow_transactions')
      .update({ payment_confirmed: true, updated_at: new Date().toISOString() })
      .eq('order_id', orderId);
  }

  // Also confirm escrow by stripe_payment_intent_id (for marketplace-escrow flow)
  await supabaseAdmin
    .from('escrow_transactions')
    .update({ payment_confirmed: true, updated_at: new Date().toISOString() })
    .eq('stripe_payment_intent_id', paymentIntent.id);

  // Record in stripe_payments if exists
  await supabaseAdmin
    .from('stripe_payments')
    .update({
      status: 'succeeded',
      updated_at: new Date().toISOString(),
    })
    .eq('payment_intent_id', paymentIntent.id);

  // Update stripe_transactions status
  await supabaseAdmin
    .from('stripe_transactions')
    .update({ status: 'SUCCEEDED', updated_at: new Date().toISOString() })
    .eq('stripe_payment_intent_id', paymentIntent.id);

  // Credit wallet if it's a deposit
  if (paymentIntent.metadata?.type === 'wallet_deposit' && userId) {
    const currency = paymentIntent.currency?.toUpperCase() || 'GNF';
    const amount = stripeAmountToReal(paymentIntent.amount, currency);

    // Crédit via la primitive canonique (verrou + plafond/quarantaine AML + ledger atomique).
    // idempotencyKey = id du PaymentIntent → Stripe peut re-livrer le webhook sans double-crédit.
    // L'ancien appel rpc('credit_wallet', {p_reference}) ne matchait AUCUNE signature (404
    // silencieux, erreur avalée) → les dépôts carte n'étaient jamais crédités.
    const creditRes = await creditWallet(
      userId,
      amount,
      `Dépôt carte Stripe (${paymentIntent.id})`,
      paymentIntent.id,
      'deposit',
      `stripe_deposit_${paymentIntent.id}`
    );
    if (!creditRes.success) {
      logger.error(`Wallet deposit credit FAILED: user=${userId}, PI=${paymentIntent.id}: ${creditRes.error}`);
    } else {
      logger.info(`Wallet credited: user=${userId}, amount=${amount} ${currency}`);
    }
  }

  await auditTrail.log({
    actorId: userId || 'stripe',
    actorType: 'webhook',
    action: 'payment.succeeded',
    resourceType: 'payment_intent',
    resourceId: paymentIntent.id,
    metadata: { orderId, amount: paymentIntent.amount },
    riskLevel: 'medium',
  });
}

async function handlePaymentIntentFailed(event: any): Promise<void> {
  const paymentIntent = event.data.object;
  const orderId = paymentIntent.metadata?.order_id;

  logger.warn(`Webhook: payment_intent.payment_failed — PI=${paymentIntent.id}, order=${orderId}`);

  if (orderId) {
    await supabaseAdmin
      .from('orders')
      .update({ payment_status: 'failed', updated_at: new Date().toISOString() })
      .eq('id', orderId);
  }

  await supabaseAdmin
    .from('stripe_payments')
    .update({ status: 'failed', updated_at: new Date().toISOString() })
    .eq('payment_intent_id', paymentIntent.id);

  await auditTrail.log({
    actorId: 'stripe',
    actorType: 'webhook',
    action: 'payment.failed',
    resourceType: 'payment_intent',
    resourceId: paymentIntent.id,
    metadata: { orderId, error: paymentIntent.last_payment_error?.message },
    riskLevel: 'high',
  });
}

async function handleChargeRefunded(event: any): Promise<void> {
  const charge = event.data.object;
  const paymentIntentId = charge.payment_intent;
  const refundAmount = charge.amount_refunded / 100;
  const isPartial = charge.amount_refunded < charge.amount;

  logger.info(`Webhook: charge.refunded — PI=${paymentIntentId}, amount=${refundAmount}, partial=${isPartial}`);

  // Find associated order
  const { data: order } = await supabaseAdmin
    .from('orders')
    .select('id, vendor_id, customer_id')
    .eq('payment_intent_id', paymentIntentId)
    .maybeSingle();

  if (order) {
    await supabaseAdmin
      .from('orders')
      .update({
        payment_status: isPartial ? 'partially_refunded' : 'refunded',
        updated_at: new Date().toISOString(),
      })
      .eq('id', order.id);

    // Update escrow
    await supabaseAdmin
      .from('escrow_transactions')
      .update({
        status: isPartial ? 'partially_refunded' : 'refunded',
        released_at: new Date().toISOString(),
      })
      .eq('order_id', order.id);
  }

  await auditTrail.log({
    actorId: 'stripe',
    actorType: 'webhook',
    action: isPartial ? 'payment.partially_refunded' : 'payment.refunded',
    resourceType: 'charge',
    resourceId: charge.id,
    metadata: { paymentIntentId, refundAmount, isPartial },
    riskLevel: 'high',
  });
}

async function handleCheckoutSessionExpired(event: any): Promise<void> {
  const session = event.data.object;
  const orderId = session.metadata?.order_id;

  logger.warn(`Webhook: checkout.session.expired — session=${session.id}, order=${orderId}`);

  if (orderId) {
    await supabaseAdmin
      .from('orders')
      .update({ payment_status: 'expired', status: 'cancelled', updated_at: new Date().toISOString() })
      .eq('id', orderId)
      .eq('status', 'pending');

    // Restore stock
    const { data: items } = await supabaseAdmin
      .from('order_items')
      .select('product_id, quantity')
      .eq('order_id', orderId);

    if (items) {
      for (const item of items) {
        await supabaseAdmin.rpc('increment_product_stock', {
          p_product_id: item.product_id,
          p_quantity: item.quantity,
        });
      }
    }

    // Refund escrow
    await supabaseAdmin
      .from('escrow_transactions')
      .update({ status: 'refunded', released_at: new Date().toISOString() })
      .eq('order_id', orderId);
  }
}

// ─────────────────────────────────────────────────────────
// STRIPE WEBHOOK HANDLER (inchangé)
// ─────────────────────────────────────────────────────────

/**
 * POST /webhooks/stripe
 * 
 * IMPORTANT: This route must receive RAW body (not parsed JSON).
 * Configure express.raw() for this route in server.ts.
 */
router.post('/stripe', webhookRateLimit, async (req: Request, res: Response) => {
  const signature = req.headers['stripe-signature'] as string;
  const webhookSecret = process.env.STRIPE_WEBHOOK_SECRET;

  if (!webhookSecret) {
    logger.error('CRITICAL: STRIPE_WEBHOOK_SECRET not configured');
    res.status(500).json({ error: 'Webhook not configured' });
    return;
  }

  if (!signature) {
    res.status(400).json({ error: 'Missing stripe-signature header' });
    return;
  }

  // Get raw body — express.raw() delivers a Buffer
  const rawBody = Buffer.isBuffer(req.body)
    ? req.body.toString('utf8')
    : typeof req.body === 'string'
      ? req.body
      : JSON.stringify(req.body);

  // Verify signature
  if (!verifyStripeSignature(rawBody, signature, webhookSecret)) {
    logger.warn('Stripe webhook: invalid signature');
    await auditTrail.log({
      actorId: 'stripe',
      actorType: 'webhook',
      action: 'webhook.signature_invalid',
      resourceType: 'webhook',
      resourceId: 'unknown',
      ip: req.ip || undefined,
      riskLevel: 'critical',
    });
    res.status(401).json({ error: 'Invalid signature' });
    return;
  }

  // Parse JSON from the validated raw body (never trust pre-parsed req.body for webhooks)
  let event: any;
  try {
    event = JSON.parse(rawBody);
  } catch {
    res.status(400).json({ error: 'Invalid JSON' });
    return;
  }

  const webhookId = event.id;
  const eventType = event.type;

  // Idempotency: skip if already processed
  if (await isAlreadyProcessed(webhookId)) {
    logger.info(`Webhook already processed: ${webhookId}`);
    res.json({ received: true, status: 'already_processed' });
    return;
  }

  // Journal: mark as processing
  await journalEvent(webhookId, eventType, event, 'processing');

  try {
    // Route to handler
    switch (eventType) {
      case 'payment_intent.succeeded':
        await handlePaymentIntentSucceeded(event);
        break;
      case 'payment_intent.payment_failed':
        await handlePaymentIntentFailed(event);
        break;
      case 'charge.refunded':
        await handleChargeRefunded(event);
        break;
      case 'checkout.session.expired':
        await handleCheckoutSessionExpired(event);
        break;
      default:
        logger.info(`Webhook: unhandled event type "${eventType}"`);
        await journalEvent(webhookId, eventType, event, 'skipped');
        res.json({ received: true, status: 'skipped' });
        return;
    }

    // Journal: mark as completed
    await journalEvent(webhookId, eventType, event, 'completed');
    logger.info(`Webhook processed: ${eventType} (${webhookId})`);
    res.json({ received: true, status: 'processed' });
  } catch (err: any) {
    logger.error(`Webhook processing error: ${err.message}`, { webhookId, eventType });
    await journalEvent(webhookId, eventType, event, 'failed', err.message);

    // Update retry count
    await supabaseAdmin
      .from('webhook_events')
      .update({ retry_count: 1 }) // Stripe will retry
      .eq('webhook_id', webhookId)
      .eq('provider', 'stripe');

    res.status(500).json({ error: 'Processing failed' });
  }
});

export default router;
