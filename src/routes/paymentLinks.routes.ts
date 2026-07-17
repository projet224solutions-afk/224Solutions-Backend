/**
 * 🔗 PAYMENT LINKS ROUTES - Backend Node.js centralisé
 *
 * Migré depuis les Edge Functions: resolve-payment-link, process-payment-link
 *
 * Endpoints:
 *   - POST /api/payment-links/resolve   — Résolution publique par token
 *   - POST /api/payment-links/process   — Traitement du paiement (wallet/card/mobile money)
 *
 * Tables: payment_links, wallets, wallet_transactions, pdg_settings
 */

import { Router, Response, Request } from 'express';
import { optionalJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { creditWallet } from '../services/wallet.service.js';
import { triggerAffiliateCommission } from '../services/commission.service.js';
import { paymentRateLimit } from '../middlewares/routeRateLimiter.js';

const router = Router();

// ─────────────────────────────────────────────────────────
// UTILS — Dynamic fee rates from pdg_settings
// ─────────────────────────────────────────────────────────

const DEFAULT_FEES: Record<string, number> = {
  commission_achats: 5,
  commission_services: 0.5,
};

const FEE_KEY_ALIASES: Record<string, string[]> = {
  commission_achats: ['purchase_commission_percentage'],
  commission_services: ['service_commissions'],
};

async function getPdgFeeRate(settingKey: string): Promise<number> {
  const defaultValue = DEFAULT_FEES[settingKey] ?? 0;
  const candidateKeys = [settingKey, ...(FEE_KEY_ALIASES[settingKey] || [])];
  try {
    for (const key of candidateKeys) {
      const { data, error } = await supabaseAdmin
        .from('pdg_settings')
        .select('setting_value')
        .eq('setting_key', key)
        .maybeSingle();

      if (error || !data) continue;

      const raw = data.setting_value;
      const rate = typeof raw === 'object' && raw !== null && 'value' in (raw as any)
        ? Number((raw as any).value)
        : Number(raw);

      if (!isNaN(rate) && rate >= 0) return rate;
    }

    return defaultValue;
  } catch {
    return defaultValue;
  }
}

async function findPaymentLinkByPublicId(publicId: string) {
  const byToken = await supabaseAdmin
    .from('payment_links')
    .select('*')
    .eq('token', publicId)
    .maybeSingle();

  if (!byToken.error && byToken.data) {
    return { data: byToken.data, error: null };
  }

  const byPaymentId = await supabaseAdmin
    .from('payment_links')
    .select('*')
    .eq('payment_id', publicId)
    .maybeSingle();

  if (!byPaymentId.error && byPaymentId.data) {
    return { data: byPaymentId.data, error: null };
  }

  return { data: null, error: byToken.error || byPaymentId.error };
}

// 🔒 Le secret Stripe vit UNIQUEMENT en process.env — jamais en base (voir CLAUDE.md).
// Le fallback DB (stripe_config.stripe_secret_key) a été RETIRÉ : un secret ne doit
// jamais résider en table. Si la clé env est absente, échec explicite en amont.
function getConfiguredStripeSecretKey(): string | null {
  return process.env.STRIPE_SECRET_KEY?.trim() || null;
}

// ── ESCROW (lien de paiement sécurisé) — helpers ────────────────────────────

// La commande légère escrow exige un customer_id (orders.customer_id NOT NULL). On le
// résout/crée à partir de l'acheteur connecté (identique à orders.routes.ts).
async function getOrCreateEscrowCustomerId(userId: string): Promise<string> {
  const { data: existing } = await supabaseAdmin
    .from('customers').select('id').eq('user_id', userId).maybeSingle();
  if (existing?.id) return existing.id;
  const { data: created, error } = await supabaseAdmin
    .from('customers').insert({ user_id: userId }).select('id').single();
  if (error) throw error;
  return created.id;
}

// La commande légère escrow exige un vendor_id (orders.vendor_id NOT NULL, FK vendors).
// On le résout depuis le lien (vendeur_id) ou depuis le compte vendeur du propriétaire.
async function resolveEscrowVendorId(link: any): Promise<string | null> {
  if (link.vendeur_id) {
    const { data: v } = await supabaseAdmin
      .from('vendors').select('id').eq('id', link.vendeur_id).maybeSingle();
    if (v?.id) return v.id;
  }
  if (link.owner_user_id) {
    const { data: v } = await supabaseAdmin
      .from('vendors').select('id').eq('user_id', link.owner_user_id).eq('is_active', true).maybeSingle();
    if (v?.id) return v.id;
  }
  return null;
}

// Traduit un code d'erreur du RPC hold_payment_link_escrow en message + statut HTTP.
function mapEscrowHoldError(rawMessage: string): { status: number; error: string } {
  const m = String(rawMessage || '');
  if (/INSUFFICIENT_FUNDS/.test(m)) return { status: 400, error: 'Solde insuffisant' };
  if (/WALLET_BLOCKED/.test(m)) return { status: 403, error: 'Wallet bloqué' };
  if (/OWN_LINK/.test(m)) return { status: 400, error: 'Vous ne pouvez pas payer votre propre lien de paiement' };
  if (/BUYER_WALLET_NOT_FOUND/.test(m)) return { status: 400, error: 'Wallet introuvable dans cette devise' };
  if (/BAD_AMOUNT|BAD_FEE/.test(m)) return { status: 400, error: 'Montant invalide' };
  if (/NOT_ESCROW_LINK|LINK_NOT_FOUND/.test(m)) return { status: 400, error: 'Lien de paiement invalide' };
  return { status: 400, error: 'Paiement sécurisé échoué' };
}

// ─────────────────────────────────────────────────────────
// POST /api/payment-links/resolve
// Résolution publique d'un lien de paiement par token
// Migré depuis resolve-payment-link Edge Function
// ─────────────────────────────────────────────────────────

router.post('/resolve', async (req: Request, res: Response) => {
  try {
    const { token } = req.body;
    const publicId = String(token || '').trim();

    if (!publicId || publicId.length < 6) {
      res.status(400).json({ success: false, error: 'Identifiant de lien invalide' });
      return;
    }

    const { data: rawLink, error } = await findPaymentLinkByPublicId(publicId);

    if (error || !rawLink) {
      res.status(404).json({ success: false, error: 'Lien de paiement introuvable' });
      return;
    }

    const link: any = {
      id: rawLink.id,
      token: rawLink.token,
      payment_id: rawLink.payment_id,
      link_type: rawLink.link_type,
      title: rawLink.title,
      produit: rawLink.produit,
      description: rawLink.description,
      montant: rawLink.montant,
      gross_amount: rawLink.gross_amount,
      platform_fee: rawLink.platform_fee,
      net_amount: rawLink.net_amount,
      frais: rawLink.frais,
      total: rawLink.total,
      devise: rawLink.devise,
      status: rawLink.status,
      expires_at: rawLink.expires_at,
      created_at: rawLink.created_at,
      is_single_use: rawLink.is_single_use,
      use_count: rawLink.use_count,
      payment_type: rawLink.payment_type,
      reference: rawLink.reference,
      owner_type: rawLink.owner_type,
      owner_user_id: rawLink.owner_user_id,
      vendeur_id: rawLink.vendeur_id,
      product_id: rawLink.product_id,
      service_id: rawLink.service_id,
      customer_name: rawLink.customer_name,
      customer_email: rawLink.customer_email,
      customer_phone: rawLink.customer_phone,
      viewed_at: rawLink.viewed_at,
      remise: rawLink.remise,
      type_remise: rawLink.type_remise,
    };

    // Check expiry (with timezone-safe comparison)
    if (link.status === 'pending' && link.expires_at) {
      const expiresAtTime = new Date(link.expires_at).getTime();
      const nowTime = Date.now();
      if (expiresAtTime < nowTime) {
        await supabaseAdmin.from('payment_links').update({ status: 'expired' }).eq('id', link.id);
        link.status = 'expired';
        logger.info(`Payment link expired: ${link.id} (expires_at: ${link.expires_at}, now: ${new Date(nowTime).toISOString()})`);
      }
    }

    // Mark as viewed
    if (!link.viewed_at && link.status === 'pending') {
      await supabaseAdmin
        .from('payment_links')
        .update({ viewed_at: new Date().toISOString() })
        .eq('id', link.id);
    }

    // Owner info
    let ownerInfo: { name: string; avatar?: string; business_name?: string } = { name: '224SOLUTIONS' };

    if (link.owner_user_id) {
      const { data: profile } = await supabaseAdmin
        .from('profiles')
        .select('first_name, last_name, avatar_url')
        .eq('id', link.owner_user_id)
        .maybeSingle();

      if (profile) {
        ownerInfo.name = `${profile.first_name || ''} ${profile.last_name || ''}`.trim() || '224SOLUTIONS';
        ownerInfo.avatar = profile.avatar_url;
      }
    }

    if (link.vendeur_id) {
      const { data: vendor } = await supabaseAdmin
        .from('vendors')
        .select('business_name, logo_url')
        .eq('id', link.vendeur_id)
        .maybeSingle();

      if (vendor) {
        ownerInfo.business_name = vendor.business_name;
        ownerInfo.avatar = vendor.logo_url || ownerInfo.avatar;
      }
    }

    // Product/Service info
    let productInfo = null;
    if (link.product_id) {
      const { data: product } = await supabaseAdmin
        .from('products')
        .select('name, description, images, price')
        .eq('id', link.product_id)
        .maybeSingle();
      if (product) productInfo = product;
    }

    let serviceInfo = null;
    if (link.service_id) {
      const { data: service } = await supabaseAdmin
        .from('professional_services')
        .select('service_name, description, category')
        .eq('id', link.service_id)
        .maybeSingle();
      if (service) serviceInfo = service;
    }

    res.json({
      success: true,
      link: {
        id: link.id,
        token: link.token,
        linkType: link.link_type,
        title: link.title || link.produit,
        description: link.description,
        amount: link.total || link.montant,
        grossAmount: link.gross_amount || link.montant,
        platformFee: link.platform_fee || link.frais,
        netAmount: link.net_amount,
        currency: link.devise,
        status: link.status,
        expiresAt: link.expires_at,
        createdAt: link.created_at,
        isSingleUse: link.is_single_use,
        paymentType: link.payment_type,
        reference: link.reference,
        ownerType: link.owner_type,
        remise: link.remise,
        typeRemise: link.type_remise,
        items: (rawLink.metadata && (rawLink.metadata as any).items) || [],
        // Lien de vente B2B adossé au stock (colonnes absentes tant que la
        // migration 20260717210000 n'est pas appliquée → undefined, sans effet).
        useCount: link.use_count ?? 0,
        maxUses: (rawLink as any).max_uses ?? null,
        targetVendorId: (rawLink as any).target_vendor_id ?? null,
        allowCredit: (rawLink as any).allow_credit ?? false,
        creditDueDays: (rawLink as any).credit_due_days ?? null,
        stockReserved: (rawLink as any).stock_reserved ?? false,
      },
      owner: ownerInfo,
      product: productInfo,
      service: serviceInfo,
    });
  } catch (err: any) {
    logger.error(`[PaymentLinks] Resolve error: ${err.message}`);
    res.status(500).json({ success: false, error: 'Erreur serveur' });
  }
});

// ─────────────────────────────────────────────────────────
// POST /api/payment-links/process
// Traitement du paiement via lien unifié
// Migré depuis process-payment-link Edge Function
// ─────────────────────────────────────────────────────────

router.post('/process', paymentRateLimit, optionalJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user?.id || null;
    const {
      token,
      paymentMethod,
      customerName,
      customerEmail,
      customerPhone,
      paymentIntentId,
    } = req.body;

    const publicId = String(token || '').trim();

    if (!publicId || !paymentMethod) {
      res.status(400).json({ success: false, error: 'Identifiant de lien et méthode de paiement requis' });
      return;
    }

    // 1. Fetch and validate link
    const { data: link, error: linkError } = await findPaymentLinkByPublicId(publicId);

    if (linkError || !link) {
      res.status(404).json({ success: false, error: 'Lien de paiement introuvable' });
      return;
    }

    if (link.status !== 'pending') {
      res.status(400).json({
        success: false,
        error: `Ce lien est déjà ${link.status === 'paid' || link.status === 'success' ? 'payé' : link.status}`
      });
      return;
    }

    // Check expiry (timezone-safe comparison)
    if (link.expires_at) {
      const expiresAtTime = new Date(link.expires_at).getTime();
      const nowTime = Date.now();
      if (expiresAtTime < nowTime) {
        await supabaseAdmin.from('payment_links').update({ status: 'expired' }).eq('id', link.id);
        res.status(410).json({ success: false, error: 'Ce lien de paiement a expiré', expiredAt: link.expires_at });
        logger.info(`Payment link expired on process attempt: ${link.id}`);
        return;
      }
    }

    if (link.is_single_use && link.use_count > 0) {
      res.status(400).json({ success: false, error: 'Ce lien a déjà été utilisé' });
      return;
    }

    // Lien de vente B2B adossé au stock : règlement UNIQUEMENT via le parcours
    // dédié (/api/b2b/links/:id/accept — réservation + commande B2B confirmée +
    // frais acheteur PDG). Le chemin générique le court-circuiterait.
    if (link.link_type === 'b2b_stock') {
      res.status(409).json({
        success: false,
        error: 'Cette offre B2B se règle depuis la page de l\'offre avec un compte vendeur 224Solutions.',
        error_code: 'B2B_LINK_USE_B2B_API',
      });
      return;
    }

    const payAmount = link.total || link.montant;
    const ownerUserId = link.owner_user_id;

    // Commission rate
    const feeKey = link.link_type === 'service' ? 'commission_services' : 'commission_achats';
    const commissionRate = await getPdgFeeRate(feeKey);
    const platformFee = Math.round(payAmount * (commissionRate / 100));
    const netAmount = payAmount - platformFee;

    logger.info(`[PaymentLinks] Process: id=${publicId}, method=${paymentMethod}, amount=${payAmount}, fee=${platformFee}`);

    // ──────── LIEN ESCROW (paiement sécurisé à la réception) ────────
    // Compte OBLIGATOIRE vérifié CÔTÉ SERVEUR (jamais de paiement escrow anonyme). On
    // pré-résout le vendeur (commande légère) AVANT tout encaissement pour ne jamais
    // capturer d'argent qu'on ne pourrait pas mettre en séquestre.
    const isEscrow = link.link_type === 'escrow';
    let escrowVendorId: string | null = null;
    let escrowCustomerId: string | null = null;
    if (isEscrow) {
      if (!userId) {
        res.status(401).json({ success: false, error: 'Ce paiement sécurisé nécessite un compte 224Solutions.', error_code: 'ESCROW_ACCOUNT_REQUIRED' });
        return;
      }
      if (!ownerUserId) {
        res.status(400).json({ success: false, error: 'Ce lien sécurisé n\'a pas de bénéficiaire' });
        return;
      }
      if (ownerUserId === userId) {
        res.status(400).json({ success: false, error: 'Vous ne pouvez pas payer votre propre lien de paiement' });
        return;
      }
      escrowVendorId = await resolveEscrowVendorId(link);
      if (!escrowVendorId) {
        res.status(400).json({ success: false, error: 'Le paiement sécurisé requiert un vendeur avec une boutique 224Solutions.', error_code: 'ESCROW_SELLER_NOT_VENDOR' });
        return;
      }
      try {
        escrowCustomerId = await getOrCreateEscrowCustomerId(userId);
      } catch (e: any) {
        logger.error(`[PaymentLinks] escrow customer resolve failed: ${e?.message}`);
        res.status(500).json({ success: false, error: 'Erreur serveur' });
        return;
      }
    }

    // ──────── WALLET PAYMENT ────────
    if (paymentMethod === 'wallet') {
      if (!userId) {
        res.status(401).json({ success: false, error: 'Connexion requise pour payer avec le wallet' });
        return;
      }

      if (!ownerUserId) {
        res.status(400).json({ success: false, error: 'Ce lien n\'a pas de bénéficiaire wallet' });
        return;
      }

      // ── LIEN ESCROW payé au wallet : SÉQUESTRE (débit acheteur, vendeur NON crédité) ──
      // hold_payment_link_escrow débite l'acheteur, crée la commande légère + l'escrow HELD,
      // et lie le tout au lien — ATOMIQUE + IDEMPOTENT (verrou lien + garde escrow_id).
      if (isEscrow) {
        const { data: hold, error: holdErr } = await supabaseAdmin.rpc('hold_payment_link_escrow', {
          p_link_id: link.id,
          p_buyer_user_id: userId,
          p_customer_id: escrowCustomerId,
          p_vendor_id: escrowVendorId,
          p_seller_user_id: ownerUserId,
          p_amount: payAmount,
          p_commission: platformFee,
          p_currency: link.devise || 'GNF',
          p_payment_method: 'wallet',
          p_payment_reference: null,
          p_debit_wallet: true,
          p_auto_release_days: 14,
        });
        if (holdErr || !hold || (hold as any).success === false) {
          const { status, error } = mapEscrowHoldError(holdErr?.message || '');
          logger.warn(`[PaymentLinks] escrow hold (wallet) échec link=${link.id}: ${holdErr?.message || 'unknown'}`);
          res.status(status).json({ success: false, error });
          return;
        }
        await supabaseAdmin.from('payment_links').update({
          customer_name: customerName || null,
          customer_email: customerEmail || null,
          customer_phone: customerPhone || null,
        }).eq('id', link.id);
        logger.info(`[PaymentLinks] escrow held (wallet): escrow=${(hold as any).escrow_id}, order=${(hold as any).order_id}`);
        res.json({
          success: true,
          paymentMethod: 'wallet',
          escrow: true,
          escrowId: (hold as any).escrow_id,
          orderId: (hold as any).order_id,
          transactionId: (hold as any).transaction_id || (hold as any).escrow_id,
          amount: payAmount,
        });
        return;
      }

      // Règlement ATOMIQUE + IDEMPOTENT (un seul RPC tout-ou-rien) : débite l'acheteur du
      // brut, crédite le NET au vendeur, la plateforme garde les frais. Anti double-paiement
      // via la clé d'idempotence (plk:<id>). Remplace l'ancien débit/crédit non transactionnel
      // qui pouvait perdre de l'argent en cas d'échec partiel.
      const { data: settle, error: settleErr } = await supabaseAdmin.rpc('settle_payment_link_atomic', {
        p_buyer_id: userId,
        p_seller_id: ownerUserId,
        p_gross: payAmount,
        p_fee: platformFee,
        p_currency: link.devise || 'GNF',
        p_reference: link.payment_id || link.id,
        p_idempotency_key: `plk:${link.id}`,
        p_description: `Paiement lien: ${link.title || link.produit}`,
      });

      if (settleErr || !settle) {
        const m = String(settleErr?.message || '');
        const friendly =
          /INSUFFICIENT_FUNDS/.test(m) ? 'Solde insuffisant' :
          /WALLET_BLOCKED/.test(m) ? 'Wallet bloqué' :
          /OWN_LINK/.test(m) ? 'Vous ne pouvez pas payer votre propre lien de paiement' :
          /BUYER_WALLET_NOT_FOUND/.test(m) ? 'Wallet introuvable' :
          /SELLER_WALLET_NOT_FOUND/.test(m) ? 'Le bénéficiaire n\'a pas de wallet' :
          /BAD_AMOUNT|BAD_FEE/.test(m) ? 'Montant invalide' :
          'Paiement échoué';
        const code = /INSUFFICIENT_FUNDS|BAD_AMOUNT|BAD_FEE|BUYER_WALLET_NOT_FOUND|SELLER_WALLET_NOT_FOUND|OWN_LINK/.test(m) ? 400
          : /WALLET_BLOCKED/.test(m) ? 403 : 400;
        logger.warn(`[PaymentLinks] settle échec link=${link.id}: ${m}`);
        res.status(code).json({ success: false, error: friendly });
        return;
      }

      const walletTxId: string | null = (settle as any).transaction_id || null;

      // Le RPC a déjà, dans UNE transaction : déplacé l'argent + marqué le lien « success »
      // + décrémenté le stock. Ici on enregistre seulement le contact client (non critique,
      // hors transaction argent — ne touche ni au statut ni à use_count).
      await supabaseAdmin.from('payment_links').update({
        customer_name: customerName || null,
        customer_email: customerEmail || null,
        customer_phone: customerPhone || null,
      }).eq('id', link.id);

      // Commission agent : l'agent du CRÉATEUR du lien (= le vendeur ownerUserId), PAS du payeur,
      // touche un % des FRAIS (platformFee), et NON du brut (sinon l'agent > frais encaissés = fuite
      // PDG). Non bloquant, idempotent par la transaction. Alignement sur le modèle marketplace.
      if (ownerUserId && platformFee > 0) {
        await triggerAffiliateCommission(ownerUserId, platformFee, 'payment_link', walletTxId || link.id);
      }

      logger.info(`[PaymentLinks] Wallet payment completed: txId=${walletTxId}, net=${netAmount}`);

      res.json({
        success: true,
        paymentMethod: 'wallet',
        transactionId: walletTxId,
        amount: payAmount,
        platformFee,
        netAmount,
      });
      return;
    }

    // ──────── CARD PAYMENT (Stripe) ────────
    if (paymentMethod === 'card') {
      const stripeKey = getConfiguredStripeSecretKey();
      if (!stripeKey) {
        res.status(503).json({ success: false, error: 'Paiement par carte non disponible (Stripe non configuré)', error_code: 'STRIPE_NOT_CONFIGURED' });
        return;
      }

      // Dynamic import of Stripe
      const { default: Stripe } = await import('stripe');
      const stripe = new Stripe(stripeKey, { apiVersion: '2023-10-16' as any });

      // ── Step 2: Finalize — verify a confirmed PaymentIntent from Stripe Elements
      if (paymentIntentId) {
        const paymentIntent = await stripe.paymentIntents.retrieve(paymentIntentId);
        if (paymentIntent.metadata?.payment_link_id !== link.id || paymentIntent.metadata?.payment_link_token !== token) {
          res.status(400).json({ success: false, error: 'Ce paiement ne correspond pas au lien fourni' });
          return;
        }
        if (paymentIntent.status !== 'succeeded') {
          res.status(400).json({
            success: false,
            error: paymentIntent.status === 'processing'
              ? 'Paiement en cours de traitement'
              : `Paiement non confirmé (${paymentIntent.status})`,
          });
          return;
        }

        // ── LIEN ESCROW payé par carte : SÉQUESTRE (Stripe encaisse, vendeur NON crédité) ──
        // L'argent est chez la plateforme (Stripe) ; on crée seulement la commande légère +
        // l'escrow HELD. IDEMPOTENT : un rejeu (même PaymentIntent) → le garde escrow_id renvoie
        // already_processed, jamais 2 escrows.
        if (isEscrow) {
          const { data: hold, error: holdErr } = await supabaseAdmin.rpc('hold_payment_link_escrow', {
            p_link_id: link.id,
            p_buyer_user_id: userId,
            p_customer_id: escrowCustomerId,
            p_vendor_id: escrowVendorId,
            p_seller_user_id: ownerUserId,
            p_amount: payAmount,
            p_commission: platformFee,
            p_currency: link.devise || 'GNF',
            p_payment_method: 'card',
            p_payment_reference: paymentIntent.id,
            p_debit_wallet: false,
            p_auto_release_days: 14,
          });
          if (holdErr || !hold || (hold as any).success === false) {
            logger.error(`[PaymentLinks] escrow hold (card) échec link=${link.id}: ${holdErr?.message || 'unknown'}`);
            res.status(500).json({ success: false, error: 'Paiement encaissé mais mise en séquestre impossible. Contactez le support.' });
            return;
          }
          await supabaseAdmin.from('payment_links').update({
            customer_name: customerName || null,
            customer_email: customerEmail || null,
            customer_phone: customerPhone || null,
          }).eq('id', link.id);
          logger.info(`[PaymentLinks] escrow held (card): escrow=${(hold as any).escrow_id}, order=${(hold as any).order_id}, intent=${paymentIntent.id}`);
          res.json({
            success: true,
            paymentMethod: 'card',
            confirmed: true,
            escrow: true,
            escrowId: (hold as any).escrow_id,
            orderId: (hold as any).order_id,
            paymentIntentId,
            amount: payAmount,
          });
          return;
        }

        await supabaseAdmin.from('payment_links').update({
          status: 'success',
          paid_at: new Date().toISOString(),
          payment_method: 'card',
          transaction_id: paymentIntent.id,
          customer_name: customerName || null,
          customer_email: customerEmail || null,
          customer_phone: customerPhone || null,
          use_count: (link.use_count || 0) + 1,
          platform_fee: platformFee,
          net_amount: netAmount,
          gross_amount: payAmount,
          wallet_credit_status: 'pending_settlement',
        }).eq('id', link.id);
        // Décrément stock (lien multi-produits) — idempotent.
        await supabaseAdmin.rpc('consume_payment_link_stock', { p_link_id: link.id }).then(() => {}, (e) => logger.warn(`[PaymentLinks] consume_stock: ${e?.message}`));
        logger.info(`[PaymentLinks] Card payment finalized: intentId=${paymentIntentId}, linkId=${link.id}`);
        res.json({ success: true, paymentMethod: 'card', confirmed: true, paymentIntentId, amount: payAmount });
        return;
      }

      const paymentIntent = await stripe.paymentIntents.create({
        amount: Math.round(payAmount),
        currency: (link.devise || 'gnf').toLowerCase(),
        automatic_payment_methods: { enabled: true },
        metadata: {
          payment_link_id: link.id,
          payment_link_token: token,
          link_type: link.link_type,
          owner_user_id: ownerUserId || '',
          platform_fee: platformFee.toString(),
          net_amount: netAmount.toString(),
          customer_name: customerName || '',
          customer_email: customerEmail || '',
        },
      });

      await supabaseAdmin.from('payment_links').update({
        payment_method: 'card',
        transaction_id: paymentIntent.id,
        customer_name: customerName || null,
        customer_email: customerEmail || null,
        customer_phone: customerPhone || null,
        platform_fee: platformFee,
        net_amount: netAmount,
        gross_amount: payAmount,
        wallet_credit_status: 'pending_settlement',
      }).eq('id', link.id);

      res.json({
        success: true,
        paymentMethod: 'card',
        clientSecret: paymentIntent.client_secret,
        paymentIntentId: paymentIntent.id,
        amount: payAmount,
      });
      return;
    }

    // ──────── MOBILE MONEY ────────
    if (paymentMethod === 'orange_money' || paymentMethod === 'mtn_momo') {
      // Escrow : pas de confirmation Mobile Money synchrone → on ne peut pas garantir le
      // séquestre des fonds. On refuse EXPLICITEMENT (jamais de séquestre sans fonds confirmés).
      // TODO : brancher un webhook Mobile Money puis autoriser l'escrow via hold_payment_link_escrow.
      if (isEscrow) {
        res.status(400).json({
          success: false,
          error: 'Le paiement sécurisé (escrow) n\'est pas disponible via Mobile Money. Utilisez le Wallet ou la carte bancaire.',
          error_code: 'ESCROW_MOBILE_UNSUPPORTED',
        });
        return;
      }
      if (!customerPhone) {
        res.status(400).json({ success: false, error: 'Numéro de téléphone requis pour Mobile Money' });
        return;
      }

      await supabaseAdmin.from('payment_links').update({
        payment_method: paymentMethod,
        customer_name: customerName || null,
        customer_email: customerEmail || null,
        customer_phone: customerPhone,
        platform_fee: platformFee,
        net_amount: netAmount,
        gross_amount: payAmount,
        wallet_credit_status: 'pending_settlement',
      }).eq('id', link.id);

      res.json({
        success: true,
        paymentMethod,
        requiresExternalPayment: true,
        amount: payAmount,
        currency: link.devise || 'GNF',
        linkId: link.id,
        linkToken: token,
        message: 'Initiez le paiement Mobile Money',
      });
      return;
    }

    res.status(400).json({ success: false, error: 'Méthode de paiement non supportée' });
  } catch (err: any) {
    logger.error(`[PaymentLinks] Process error: ${err.message}`);
    res.status(500).json({ success: false, error: 'Erreur serveur' });
  }
});

export default router;
