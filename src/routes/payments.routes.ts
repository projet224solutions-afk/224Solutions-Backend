/**
 * 💳 PAYMENTS ROUTES - Backend Node.js centralisé
 *
 * Endpoints de paiement gérés côté Node.js :
 *   - Liens de paiement (lecture publique + confirmation)
 *   - Paiement sécurisé avec signature HMAC (init + validate / wallet deposit)
 *   - Historique et résumé des transactions
 *
 * Tables utilisées :
 *   - `payment_links`, `wallet_transactions`, `wallets`, `secure_transactions`,
 *     `financial_audit_logs`
 */

import { Router, Response } from 'express';
import crypto from 'crypto';
import { optionalJWT, verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { paymentRateLimit } from '../middlewares/routeRateLimiter.js';
import { triggerAffiliateCommission } from '../services/commission.service.js';
import { creditWallet } from '../services/wallet.service.js';
import { emitCoreFeatureEvent } from '../services/coreFeatureEvents.service.js';

const router = Router();

async function ignoreSupabaseError(operation: PromiseLike<unknown> | unknown): Promise<void> {
  await Promise.resolve(operation).catch(() => undefined);
}

function isValidStripePublishableKey(key: string | undefined | null): key is string {
  return Boolean(key?.trim().match(/^pk_(test|live)_[A-Za-z0-9]{20,}$/));
}

async function getConfiguredStripePublishableKey(): Promise<string | null> {
  const envKey = (
    process.env.STRIPE_PUBLISHABLE_KEY ||
    process.env.STRIPE_PUBLIC_KEY ||
    process.env.VITE_STRIPE_PUBLISHABLE_KEY ||
    ''
  ).trim();

  if (isValidStripePublishableKey(envKey)) {
    return envKey;
  }

  try {
    const { data, error } = await supabaseAdmin
      .from('stripe_config')
      .select('stripe_publishable_key')
      .limit(1)
      .maybeSingle();

    if (error) {
      logger.warn(`[Stripe Config] stripe_config inaccessible: ${error.message}`);
      return null;
    }

    const dbKey = data?.stripe_publishable_key?.trim();
    return isValidStripePublishableKey(dbKey) ? dbKey : null;
  } catch (error: any) {
    logger.warn(`[Stripe Config] fallback stripe_config échoué: ${error?.message || 'unknown'}`);
    return null;
  }
}

// Apply payment rate limit to all payment routes
router.use(paymentRateLimit);

/**
 * GET /api/payments/stripe/config
 * Expose uniquement la clé publique Stripe au frontend.
 * La clé secrète reste strictement côté backend.
 */
router.get('/stripe/config', async (_req, res: Response) => {
  const publishableKey = await getConfiguredStripePublishableKey();

  if (!publishableKey) {
    res.status(503).json({
      success: false,
      error: 'Clé publique Stripe non configurée',
    });
    return;
  }

  res.json({
    success: true,
    publishableKey,
  });
});

/**
 * GET /api/payments/link/:paymentId
 * Lecture publique securisee d'un lien de paiement
 */
router.get('/link/:paymentId', optionalJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { paymentId } = req.params;

    const { data, error } = await supabaseAdmin
      .from('payment_links')
      .select(`
        id,
        payment_id,
        produit,
        description,
        montant,
        remise,
        type_remise,
        frais,
        total,
        devise,
        status,
        expires_at,
        created_at,
        client_id,
        vendeur:vendors!payment_links_vendeur_id_fkey(
          id,
          business_name
        )
      `)
      .eq('payment_id', paymentId)
      .maybeSingle();

    if (error) throw error;

    if (!data) {
      res.status(404).json({ success: false, error: 'Lien de paiement non trouvé' });
      return;
    }

    const now = new Date();
    const expiresAt = new Date(data.expires_at);
    const isExpired = expiresAt.getTime() <= now.getTime();

    // Si client ciblé, on impose l'authentification du client concerné
    if (data.client_id && req.user?.id !== data.client_id) {
      if (!req.user?.id) {
        res.status(401).json({ success: false, error: 'Connexion requise pour ce lien de paiement' });
        return;
      }
      res.status(403).json({ success: false, error: 'Ce lien est réservé à un client spécifique' });
      return;
    }

    if (isExpired && data.status === 'pending') {
      await supabaseAdmin
        .from('payment_links')
        .update({ status: 'expired' })
        .eq('id', data.id)
        .eq('status', 'pending');
      data.status = 'expired';
    }

    res.json({
      success: true,
      payment: {
        id: data.id,
        payment_id: data.payment_id,
        produit: data.produit,
        description: data.description,
        montant: Number(data.montant || 0),
        remise: Number(data.remise || 0),
        type_remise: data.type_remise,
        frais: Number(data.frais || 0),
        total: Number(data.total || 0),
        devise: data.devise,
        status: data.status,
        expires_at: data.expires_at,
        created_at: data.created_at,
        vendeur: {
          name: (data.vendeur as any)?.business_name || 'Vendeur'
        }
      }
    });
  } catch (error: any) {
    logger.error(`Error fetching payment link: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors du chargement du lien de paiement' });
  }
});

/**
 * POST /api/payments/link/:paymentId/pay
 * Confirmation de paiement d'un lien public
 */
router.post('/link/:paymentId/pay', optionalJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { paymentId } = req.params;
    const { payment_method, transaction_id, client_info } = req.body || {};

    if (!payment_method) {
      res.status(400).json({ success: false, error: 'payment_method requis' });
      return;
    }

    const { data: current, error: fetchError } = await supabaseAdmin
      .from('payment_links')
      .select('id, status, expires_at, client_id, metadata')
      .eq('payment_id', paymentId)
      .maybeSingle();

    if (fetchError) throw fetchError;

    if (!current) {
      res.status(404).json({ success: false, error: 'Lien de paiement non trouvé' });
      return;
    }

    if (current.client_id && req.user?.id !== current.client_id) {
      if (!req.user?.id) {
        res.status(401).json({ success: false, error: 'Connexion requise pour ce lien de paiement' });
        return;
      }
      res.status(403).json({ success: false, error: 'Ce lien est réservé à un client spécifique' });
      return;
    }

    if (current.status !== 'pending') {
      res.status(409).json({ success: false, error: `Lien déjà traité (status=${current.status})` });
      return;
    }

    if (new Date(current.expires_at).getTime() <= Date.now()) {
      await supabaseAdmin
        .from('payment_links')
        .update({ status: 'expired' })
        .eq('id', current.id)
        .eq('status', 'pending');
      res.status(410).json({ success: false, error: 'Lien expiré' });
      return;
    }

    const fallbackTxn = `plink_${Date.now()}_${Math.random().toString(36).slice(2, 10)}`;
    const nextMetadata = {
      ...(current.metadata || {}),
      client_info: client_info || null,
      paid_via: payment_method,
      paid_by_user_id: req.user?.id || null,
      source: 'api_payments_link_pay',
    };

    const { data: updated, error: updateError } = await supabaseAdmin
      .from('payment_links')
      .update({
        status: 'success',
        paid_at: new Date().toISOString(),
        payment_method,
        transaction_id: transaction_id || fallbackTxn,
        metadata: nextMetadata,
      })
      .eq('id', current.id)
      .eq('status', 'pending')
      .select('payment_id, status, transaction_id')
      .maybeSingle();

    if (updateError) throw updateError;

    if (!updated) {
      await emitCoreFeatureEvent({
        featureKey: 'payment.links.pay',
        coreEngine: 'payment',
        ownerModule: 'payment_links',
        criticality: 'critical',
        status: 'degraded',
        userId: req.user?.id || null,
        payload: { payment_id: paymentId, reason: 'parallel_update_conflict' },
      });
      res.status(409).json({ success: false, error: 'Le lien a été traité en parallèle, veuillez rafraîchir' });
      return;
    }

    await emitCoreFeatureEvent({
      featureKey: 'payment.links.pay',
      coreEngine: 'payment',
      ownerModule: 'payment_links',
      criticality: 'critical',
      status: 'success',
      userId: req.user?.id || null,
      payload: { payment_id: paymentId, payment_method },
    });

    res.json({ success: true, payment: updated });
  } catch (error: any) {
    logger.error(`Error confirming payment link: ${error.message}`);
    await emitCoreFeatureEvent({
      featureKey: 'payment.links.pay',
      coreEngine: 'payment',
      ownerModule: 'payment_links',
      criticality: 'critical',
      status: 'failure',
      userId: req.user?.id || null,
      payload: { payment_id: req.params.paymentId, error: error.message },
    });
    res.status(500).json({ success: false, error: 'Erreur lors de la confirmation du paiement' });
  }
});

// ─────────────────────────────────────────────────────────
// PAIEMENT SÉCURISÉ (Init + Validate) — WALLET DEPOSIT
// Migré depuis les Edge Functions secure-payment-init / secure-payment-validate
// ─────────────────────────────────────────────────────────

const FEE_PERCENTAGE = 0.025; // 2.5%

function computeSecureSignature(transactionId: string, totalAmount: number): string {
  const secret = process.env.TRANSACTION_SECRET_KEY;
  if (!secret) throw new Error('CRITICAL: TRANSACTION_SECRET_KEY non configuré');
  return crypto
    .createHmac('sha256', secret)
    .update(`${transactionId}${totalAmount}`)
    .digest('hex');
}

/**
 * POST /api/payments/secure/init
 * Initialise un paiement wallet sécurisé (calcul de frais côté serveur + signature HMAC).
 * Remplace l'Edge Function secure-payment-init.
 *
 * Auth : verifyJWT (authentification obligatoire)
 * Body : { requested_amount, payment_method?, transaction_type?, interface_type? }
 */
router.post('/secure/init', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const {
      requested_amount,
      payment_method = 'OM',
      transaction_type = 'deposit',
      interface_type = 'client',
    } = req.body || {};

    if (!requested_amount || typeof requested_amount !== 'number' || requested_amount <= 0) {
      res.status(400).json({ success: false, error: 'INVALID_AMOUNT', message: 'Montant invalide' });
      return;
    }

    // Vérifier si l'utilisateur est bloqué
    const { data: securityFlags } = await supabaseAdmin
      .from('user_security_flags')
      .select('is_blocked, blocked_reason')
      .eq('user_id', userId)
      .maybeSingle();

    if (securityFlags?.is_blocked) {
      await ignoreSupabaseError(supabaseAdmin.from('financial_audit_logs').insert({
        user_id: userId,
        action_type: 'attempt',
        description: 'Tentative de paiement par utilisateur bloqué',
        is_suspicious: true,
        security_flags: ['blocked_user_attempt'],
        ip_address: req.headers['x-forwarded-for'] || req.ip,
        user_agent: req.headers['user-agent'],
      }));

      res.status(403).json({ success: false, error: 'USER_BLOCKED', message: 'Compte bloqué' });
      return;
    }

    // Calcul des montants côté serveur (jamais depuis le frontend)
    const feeAmount = Math.round(requested_amount * FEE_PERCENTAGE * 100) / 100;
    const totalAmount = requested_amount + feeAmount;
    const netAmount = requested_amount;
    const transactionId = crypto.randomUUID();
    const signature = computeSecureSignature(transactionId, totalAmount);

    const { error: insertError } = await supabaseAdmin
      .from('secure_transactions')
      .insert({
        id: transactionId,
        user_id: userId,
        requested_amount,
        fee_percentage: FEE_PERCENTAGE,
        fee_amount: feeAmount,
        total_amount: totalAmount,
        net_amount: netAmount,
        signature_hash: signature,
        transaction_type,
        interface_type,
        payment_method,
        status: 'pending',
        payment_provider: 'wallet',
        ip_address: req.headers['x-forwarded-for'] || req.ip,
        user_agent: req.headers['user-agent'],
      });

    if (insertError) {
      logger.error(`[SecurePayment] Init insert error: ${insertError.message}`);
      res.status(500).json({ success: false, error: 'TRANSACTION_CREATION_FAILED' });
      return;
    }

    await ignoreSupabaseError(supabaseAdmin.from('financial_audit_logs').insert({
      transaction_id: transactionId,
      user_id: userId,
      action_type: 'create',
      description: `Transaction sécurisée créée - Total: ${totalAmount} GNF`,
      new_status: 'pending',
      request_data: { requested_amount, fee_amount: feeAmount, total_amount: totalAmount },
      ip_address: req.headers['x-forwarded-for'] || req.ip,
    }));

    logger.info(`[SecurePayment] Init: user=${userId}, total=${totalAmount}, tx=${transactionId}`);

    await emitCoreFeatureEvent({
      featureKey: 'payment.secure.init',
      coreEngine: 'payment',
      ownerModule: 'secure_payment',
      criticality: 'high',
      status: 'success',
      userId,
      payload: { transaction_id: transactionId, total_amount: totalAmount },
    });

    res.json({
      success: true,
      transaction_id: transactionId,
      requested_amount,
      fee_amount: feeAmount,
      total_amount: totalAmount,
      net_amount: netAmount,
      signature,
      payment_method,
      status: 'pending',
    });
  } catch (error: any) {
    logger.error(`[SecurePayment] Init error: ${error.message}`);
    await emitCoreFeatureEvent({
      featureKey: 'payment.secure.init',
      coreEngine: 'payment',
      ownerModule: 'secure_payment',
      criticality: 'high',
      status: 'failure',
      userId: req.user?.id || null,
      payload: { error: error.message },
    });
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * POST /api/payments/secure/validate
 * Valide un paiement sécurisé (vérifie signature HMAC + montant + statut).
 * Si tout est correct, crédite le wallet.
 * Remplace l'Edge Function secure-payment-validate.
 *
 * Auth : verifyJWT (ou appel S2S avec signature)
 * Body : { transaction_id, external_transaction_id, amount_paid, payment_status, signature }
 */
router.post('/secure/validate', optionalJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const {
      transaction_id,
      external_transaction_id,
      amount_paid,
      payment_status,
      signature,
    } = req.body || {};

    if (!transaction_id) {
      res.status(400).json({ success: false, error: 'transaction_id requis' });
      return;
    }

    // Récupérer la transaction
    const { data: transaction, error: fetchError } = await supabaseAdmin
      .from('secure_transactions')
      .select('*')
      .eq('id', transaction_id)
      .single();

    if (fetchError || !transaction) {
      await ignoreSupabaseError(supabaseAdmin.from('financial_audit_logs').insert({
        user_id: '00000000-0000-0000-0000-000000000000',
        action_type: 'attempt',
        description: 'Tentative validation avec ID transaction invalide',
        request_data: { transaction_id },
        is_suspicious: true,
        security_flags: ['invalid_transaction_id'],
      }));

      res.status(404).json({ success: false, error: 'TRANSACTION_NOT_FOUND' });
      return;
    }

    const userId = transaction.user_id;

    // Vérifier statut pending
    if (transaction.status !== 'pending') {
      res.status(400).json({
        success: false,
        error: 'INVALID_TRANSACTION_STATUS',
        current_status: transaction.status,
      });
      return;
    }

    // Vérifier la signature HMAC (règle de sécurité absolue)
    let expectedSignature: string;
    try {
      expectedSignature = computeSecureSignature(transaction_id, transaction.total_amount);
    } catch (sigErr: any) {
      res.status(500).json({ success: false, error: 'SIGNATURE_CONFIG_ERROR' });
      return;
    }

    if (!signature || signature !== expectedSignature) {
      await ignoreSupabaseError(supabaseAdmin.from('financial_security_alerts').insert({
        transaction_id,
        user_id: userId,
        alert_type: 'signature_invalid',
        severity: 'critical',
        title: 'Signature API invalide',
        description: 'Tentative de validation avec signature incorrecte',
        expected_value: expectedSignature,
        received_value: signature || 'NULL',
      }));

      await supabaseAdmin
        .from('secure_transactions')
        .update({ status: 'rejected', rejection_reason: 'INVALID_SIGNATURE', failed_at: new Date().toISOString() })
        .eq('id', transaction_id);

      await ignoreSupabaseError(supabaseAdmin.from('financial_audit_logs').insert({
        transaction_id,
        user_id: userId,
        action_type: 'reject',
        description: 'SIGNATURE INVALIDE — Paiement REFUSÉ',
        is_suspicious: true,
        security_flags: ['invalid_signature'],
      }));

      res.status(403).json({ success: false, error: 'INVALID_SIGNATURE', message: 'Paiement REFUSÉ' });
      return;
    }

    // Vérifier le statut du paiement
    if (payment_status !== 'SUCCESS' && payment_status !== 'completed') {
      await supabaseAdmin
        .from('secure_transactions')
        .update({
          status: 'failed',
          rejection_reason: `PAYMENT_${String(payment_status || 'FAILED').toUpperCase()}`,
          external_transaction_id,
          failed_at: new Date().toISOString(),
        })
        .eq('id', transaction_id);

      res.status(400).json({ success: false, error: 'PAYMENT_FAILED', status: payment_status });
      return;
    }

    // Vérifier l'exact montant payé
    const amountDiff = Math.abs(Number(amount_paid) - Number(transaction.total_amount));
    if (!amount_paid || amountDiff > 0.01) {
      await ignoreSupabaseError(supabaseAdmin.from('financial_security_alerts').insert({
        transaction_id,
        user_id: userId,
        alert_type: 'amount_mismatch',
        severity: 'critical',
        title: 'Montant payé différent',
        description: 'Le montant payé ne correspond pas au montant attendu',
        expected_value: String(transaction.total_amount),
        received_value: String(amount_paid ?? 'NULL'),
      }));

      await supabaseAdmin
        .from('secure_transactions')
        .update({ status: 'rejected', rejection_reason: 'AMOUNT_MISMATCH', failed_at: new Date().toISOString() })
        .eq('id', transaction_id);

      res.status(400).json({
        success: false,
        error: 'AMOUNT_MISMATCH',
        expected: transaction.total_amount,
        received: amount_paid,
      });
      return;
    }

    // ── TOUTES LES VALIDATIONS OK → Créditer le wallet (ATOMIQUE + IDEMPOTENT + AML) ──
    // Via creditWallet → credit_user_wallet_safe : verrou/création du wallet, plafond de
    // détention AML + quarantaine de l'excédent, garde devise, et clé d'idempotence
    // (anti double-crédit au rejeu/concurrence). Remplace l'ancien read-modify-write brut
    // du solde (course = perte ou duplication d'argent) et le journal manuel.
    const creditRes = await creditWallet(
      userId,
      Number(transaction.net_amount),
      `Recharge sécurisée via ${transaction.payment_method || 'mobile money'}`,
      external_transaction_id || transaction_id,
      'deposit',
      `secure:${transaction_id}`,
    );

    if (!creditRes.success) {
      logger.error(`[SecurePayment] Wallet credit failed: ${creditRes.error}`);
      res.status(500).json({ success: false, error: 'WALLET_CREDIT_FAILED' });
      return;
    }

    const newBalance = creditRes.newBalance ?? null;

    // Marquer la transaction comme complétée
    await supabaseAdmin
      .from('secure_transactions')
      .update({
        status: 'completed',
        signature_verified: true,
        external_transaction_id,
        amount_paid,
        validated_at: new Date().toISOString(),
        completed_at: new Date().toISOString(),
      })
      .eq('id', transaction_id);

    // Déclencher les commissions affiliées
    await triggerAffiliateCommission(userId, Number(transaction.net_amount), 'wallet_deposit', transaction_id);

    await ignoreSupabaseError(supabaseAdmin.from('financial_audit_logs').insert({
      transaction_id,
      user_id: userId,
      action_type: 'complete',
      description: `Paiement validé et wallet crédité: ${transaction.net_amount} GNF`,
      old_status: 'pending',
      new_status: 'completed',
    }));

    logger.info(`[SecurePayment] Validated: user=${userId}, net=${transaction.net_amount}, newBalance=${newBalance}`);

    await emitCoreFeatureEvent({
      featureKey: 'payment.secure.validate',
      coreEngine: 'payment',
      ownerModule: 'secure_payment',
      criticality: 'critical',
      status: 'success',
      userId,
      payload: { transaction_id, net_amount: transaction.net_amount },
    });

    res.json({
      success: true,
      message: 'Paiement validé et wallet crédité',
      credited_amount: transaction.net_amount,
      new_balance: newBalance,
      transaction_id,
    });
  } catch (error: any) {
    logger.error(`[SecurePayment] Validate error: ${error.message}`);
    await emitCoreFeatureEvent({
      featureKey: 'payment.secure.validate',
      coreEngine: 'payment',
      ownerModule: 'secure_payment',
      criticality: 'critical',
      status: 'failure',
      userId: req.user?.id || null,
      payload: { transaction_id: req.body?.transaction_id || null, error: error.message },
    });
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

// ─────────────────────────────────────────────────────────
// HISTORIQUE DES PAIEMENTS
// ─────────────────────────────────────────────────────────

/**
 * GET /api/payments/
 * Historique des paiements de l'utilisateur (via wallet_transactions)
 */
router.get('/', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const limit = Math.min(parseInt(req.query.limit as string) || 20, 100);
    const offset = parseInt(req.query.offset as string) || 0;
    const status = req.query.status as string;

    let query = supabaseAdmin
      .from('wallet_transactions')
      .select('*', { count: 'exact' })
      .or(`sender_user_id.eq.${userId},receiver_user_id.eq.${userId}`)
      .order('created_at', { ascending: false })
      .range(offset, offset + limit - 1);

    if (status) {
      query = query.eq('status', status);
    }

    const { data, error, count } = await query;

    if (error) throw error;

    res.json({
      success: true,
      data: data || [],
      meta: { limit, offset, total: count || 0, hasMore: (offset + limit) < (count || 0) }
    });
  } catch (error: any) {
    logger.error(`Error fetching payment history: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur' });
  }
});

/**
 * GET /api/payments/:transactionId
 * Détails d'une transaction spécifique
 */
router.get('/:transactionId', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const { transactionId } = req.params;

    // Chercher par transaction_id (VARCHAR) ou par id (BIGINT)
    const { data, error } = await supabaseAdmin
      .from('wallet_transactions')
      .select('*')
      .or(`transaction_id.eq.${transactionId},id.eq.${transactionId}`)
      .or(`sender_user_id.eq.${userId},receiver_user_id.eq.${userId}`)
      .maybeSingle();

    if (error) throw error;

    if (!data) {
      res.status(404).json({ success: false, error: 'Transaction non trouvée' });
      return;
    }

    res.json({ success: true, data });
  } catch (error: any) {
    logger.error(`Error fetching payment: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur' });
  }
});

/**
 * GET /api/payments/summary
 * Résumé des paiements (total envoyé, total reçu, nb transactions)
 */
router.get('/summary/me', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;

    // Transactions envoyées (complétées)
    const { data: sent, error: sentError } = await supabaseAdmin
      .from('wallet_transactions')
      .select('amount, fee, currency')
      .eq('sender_user_id', userId)
      .eq('status', 'completed');

    if (sentError) throw sentError;

    // Transactions reçues (complétées)
    const { data: received, error: receivedError } = await supabaseAdmin
      .from('wallet_transactions')
      .select('net_amount, currency')
      .eq('receiver_user_id', userId)
      .eq('status', 'completed');

    if (receivedError) throw receivedError;

    const totalSent = (sent || []).reduce((sum, t) => sum + Number(t.amount), 0);
    const totalFees = (sent || []).reduce((sum, t) => sum + Number(t.fee || 0), 0);
    const totalReceived = (received || []).reduce((sum, t) => sum + Number(t.net_amount), 0);

    res.json({
      success: true,
      data: {
        total_sent: totalSent,
        total_fees: totalFees,
        total_received: totalReceived,
        transactions_sent: (sent || []).length,
        transactions_received: (received || []).length,
        currency: 'GNF'
      }
    });
  } catch (error: any) {
    logger.error(`Error fetching payment summary: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur' });
  }
});

export default router;
