/**
 * 💰 SUBSCRIPTIONS ROUTES - Phase 2 (alignée DB existante)
 *
 * Tables utilisées :
 *   - `plans` : id, name, display_name, monthly_price_gnf, yearly_price_gnf, max_products, max_images_per_product, etc.
 *   - `subscriptions` : user_id, plan_id, price_paid_gnf, billing_cycle, status, etc.
 *
 * Statuts valides (alignés avec l'existant) :
 *   - active      : abonnement payé et confirmé (ou gratuit)
 *   - trialing    : abonnement payant en attente de confirmation de paiement
 *   - cancelled   : abonnement annulé par l'utilisateur
 *   - expired     : abonnement expiré (période terminée ou trialing jamais confirmé)
 *   - past_due    : échec de renouvellement, paiement en retard
 *
 * Flow subscribe → confirm :
 *   1. POST /subscribe crée un abonnement :
 *      - Plan gratuit (price = 0) → statut 'active' immédiatement
 *      - Plan payant → statut 'trialing', expire automatiquement après 48h si non confirmé
 *   2. POST /confirm active un abonnement 'trialing' après paiement validé → 'active'
 *   3. POST /expire-stale (interne/cron) nettoie les abonnements 'trialing' jamais confirmés
 */

import { Router, Response } from 'express';
import { verifyJWT, requireRole } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { randomUUID } from 'crypto';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { triggerAffiliateCommission } from '../services/commission.service.js';
// Les abonnements utilisent désormais les RPC atomiques (débit + écriture en 1 transaction)
// au lieu de debitWallet/creditWallet (pattern saga). Voir migration 20260604030000.
import { subscriptionRateLimit } from '../middlewares/routeRateLimiter.js';

const router = Router();

// ==================== Helper : résultat des RPC atomiques d'abonnement ====================
type AtomicSubResult = { status: 'created' | 'error'; subscription_id?: string; new_balance?: number; mode?: string; error?: string };

function mapAtomicSubError(err?: string): { status: number; message: string } {
  const e = err || '';
  if (e.includes('DUPLICATE_PAYMENT')) return { status: 409, message: 'Paiement déjà traité (doublon détecté)' };
  if (e.includes('INSUFFICIENT_FUNDS')) return { status: 400, message: 'Solde insuffisant' };
  if (e.includes('INVALID_AMOUNT')) return { status: 400, message: 'Montant invalide' };
  if (e.includes('WALLET_BLOCKED')) return { status: 400, message: 'Wallet bloqué' };
  if (e.includes('WALLET_NOT_FOUND')) return { status: 400, message: 'Wallet introuvable' };
  if (e.includes('SUBSCRIPTION_NOT_FOUND')) return { status: 404, message: 'Abonnement introuvable' };
  return { status: 500, message: 'Erreur lors de la souscription' };
}

// ==================== Statuts autorisés ====================
const VALID_STATUSES = ['active', 'cancelled', 'expired', 'trialing', 'past_due'] as const;
type SubscriptionStatus = typeof VALID_STATUSES[number];

// ==================== Limites plan gratuit (chargées depuis DB) ====================
// Ne plus jamais hardcoder — ces valeurs sont lues depuis plans WHERE name = 'free'
let FREE_PLAN_FALLBACK = {
  max_products: 5 as number | null,
  max_images_per_product: 3 as number | null,
  analytics_access: false,
  priority_support: false,
  featured_products: false,
  api_access: false,
  custom_branding: false,
};

// Charger les limites du plan gratuit depuis la DB au premier appel
let freePlanFallbackLoaded = false;
async function loadFreePlanFallback() {
  if (freePlanFallbackLoaded) return;
  try {
    const { data } = await supabaseAdmin
      .from('plans')
      .select('max_products, max_images_per_product, analytics_access, priority_support, featured_products, api_access, custom_branding')
      .eq('name', 'free')
      .eq('is_active', true)
      .maybeSingle();
    if (data) {
      FREE_PLAN_FALLBACK = {
        max_products: data.max_products,
        max_images_per_product: data.max_images_per_product,
        analytics_access: data.analytics_access ?? false,
        priority_support: data.priority_support ?? false,
        featured_products: data.featured_products ?? false,
        api_access: data.api_access ?? false,
        custom_branding: data.custom_branding ?? false,
      };
    }
    freePlanFallbackLoaded = true;
  } catch (e) {
    logger.error('Failed to load free plan fallback from DB:', e);
  }
}

// Délai maximum pour confirmer un abonnement trialing (48h)
const TRIALING_EXPIRY_HOURS = 48;

/**
 * GET /api/subscriptions/plans
 * Liste les plans d'abonnement depuis la table `plans`
 */
router.get('/plans', async (_req, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin
      .from('plans')
      .select('*')
      .eq('is_active', true)
      .order('display_order', { ascending: true });

    if (error) throw error;

    res.json({ success: true, data: data || [] });
  } catch (error: any) {
    logger.error(`Error fetching plans: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la récupération des plans' });
  }
});

/**
 * GET /api/subscriptions/current
 * Abonnement actuel de l'utilisateur depuis la table `subscriptions`
 */
router.get('/current', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;

    const { data, error } = await supabaseAdmin
      .from('subscriptions')
      .select('*, plans(*)')
      .eq('user_id', userId)
      .in('status', ['active', 'trialing'])
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();

    if (error) throw error;

    res.json({ success: true, data: data || null });
  } catch (error: any) {
    logger.error(`Error fetching subscription: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la récupération de l\'abonnement' });
  }
});

/**
 * GET /api/subscriptions/history
 * Historique des abonnements
 */
router.get('/history', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const limit = Math.min(parseInt(req.query.limit as string) || 20, 100);
    const offset = parseInt(req.query.offset as string) || 0;

    const { data, error, count } = await supabaseAdmin
      .from('subscriptions')
      .select('*, plans(name, display_name)', { count: 'exact' })
      .eq('user_id', userId)
      .order('created_at', { ascending: false })
      .range(offset, offset + limit - 1);

    if (error) throw error;

    res.json({
      success: true,
      data: data || [],
      meta: { limit, offset, total: count || 0, hasMore: (offset + limit) < (count || 0) }
    });
  } catch (error: any) {
    logger.error(`Error fetching subscription history: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur' });
  }
});

/**
 * POST /api/subscriptions/subscribe
 *
 * Initie une souscription — ne met PAS directement en 'active' pour les plans payants.
 *
 * Flow :
 *   1. Vérifie que le plan existe et est actif
 *   2. Vérifie qu'il n'y a pas d'abonnement actif (ni en trialing)
 *   3. Si plan gratuit (monthly_price_gnf = 0) → status = 'active' immédiatement
 *   4. Si plan payant → status = 'trialing', avec expiration automatique à +48h
 *   5. L'activation réelle du plan payant se fait via POST /confirm après paiement validé
 *
 * Protection anti-fantômes :
 *   - Les abonnements en 'trialing' ont un champ trial_ends_at = now() + 48h
 *   - Le cron/endpoint /expire-stale passe en 'expired' tous les trialing dépassés
 */
router.post('/subscribe', verifyJWT, subscriptionRateLimit, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const { plan_id, billing_cycle = 'monthly', payment_method } = req.body;

    if (!plan_id) {
      res.status(400).json({ success: false, error: 'plan_id requis' });
      return;
    }

    // 1. Vérifier le plan dans la table `plans`
    const { data: plan, error: planError } = await supabaseAdmin
      .from('plans')
      .select('*')
      .eq('id', plan_id)
      .eq('is_active', true)
      .single();

    if (planError || !plan) {
      res.status(404).json({ success: false, error: 'Plan non trouvé ou inactif' });
      return;
    }

    // 2. Vérifier pas d'abonnement actif ni en trialing
    const { data: existing } = await supabaseAdmin
      .from('subscriptions')
      .select('id, status')
      .eq('user_id', userId)
      .in('status', ['active', 'trialing'])
      .limit(1)
      .maybeSingle();

    if (existing) {
      res.status(409).json({
        success: false,
        error: existing.status === 'trialing'
          ? 'Un abonnement en attente de paiement existe déjà. Confirmez-le ou attendez son expiration.'
          : 'Un abonnement actif existe déjà',
        current_status: existing.status,
        existing_id: existing.id
      });
      return;
    }

    // 3. Calculer le prix selon le cycle
    const pricePaid = billing_cycle === 'yearly' && plan.yearly_price_gnf
      ? plan.yearly_price_gnf
      : plan.monthly_price_gnf;

    // 4. Déterminer le statut initial
    const isFree = pricePaid === 0;
    const initialStatus: SubscriptionStatus = isFree ? 'active' : 'trialing';

    // 5. Calculer les dates de période
    const now = new Date();
    const periodEnd = new Date(now);
    if (billing_cycle === 'yearly') {
      periodEnd.setFullYear(periodEnd.getFullYear() + 1);
    } else {
      periodEnd.setMonth(periodEnd.getMonth() + 1);
    }

    // 6. Pour les plans payants, définir une date d'expiration du trialing
    const trialEndsAt = isFree ? null : new Date(now.getTime() + TRIALING_EXPIRY_HOURS * 60 * 60 * 1000);

    // 7. Créer l'abonnement dans la table `subscriptions`
    const { data: subscription, error: subError } = await supabaseAdmin
      .from('subscriptions')
      .insert({
        user_id: userId,
        plan_id,
        price_paid_gnf: pricePaid,
        billing_cycle,
        status: initialStatus,
        started_at: now.toISOString(),
        current_period_start: now.toISOString(),
        current_period_end: periodEnd.toISOString(),
        trial_ends_at: trialEndsAt?.toISOString() || null,
        auto_renew: isFree ? false : true,
        payment_method: payment_method || null,
        metadata: {
          initiated_from: 'backend_v2',
          plan_name: plan.name,
          requires_payment: !isFree,
          trialing_expires_at: trialEndsAt?.toISOString() || null,
        }
      })
      .select('*, plans(name, display_name, max_products)')
      .single();

    if (subError) throw subError;

    logger.info(`Subscription created: user=${userId}, plan=${plan.name}, status=${initialStatus}, price=${pricePaid} GNF${trialEndsAt ? `, trialing expires=${trialEndsAt.toISOString()}` : ''}`);

    res.status(201).json({
      success: true,
      data: subscription,
      requires_payment: !isFree,
      trialing_expires_at: trialEndsAt?.toISOString() || null,
      message: isFree
        ? 'Abonnement gratuit activé'
        : `Abonnement en attente de paiement. Vous avez ${TRIALING_EXPIRY_HOURS}h pour confirmer.`
    });
  } catch (error: any) {
    logger.error(`Error creating subscription: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la création de l\'abonnement' });
  }
});

/**
 * POST /api/subscriptions/purchase
 *
 * Achat d'abonnement avec débit wallet — TOUTE la logique en backend Node.js
 * (remplace l'ancienne RPC Postgres `record_subscription_payment` / `subscribe_user`).
 *
 * Flow atomique-séquentiel :
 *   1. Charger le plan + calculer le prix selon le cycle (mensuel/trimestriel/annuel)
 *   2. CHANGEMENT DE PLAN avant expiration (abonnement payant actif non expiré) :
 *        montant facturé = max(0, prix_nouveau_plan − montant_déjà_payé)
 *        - upgrade (Pro→Business) → on facture seulement la différence (Pro déduit)
 *        - downgrade (Premium→Business) → différence ≤ 0 → AUCUN débit
 *        La période déjà payée (current_period_end) est conservée.
 *   3. Sinon (nouvel abonnement / renouvellement) : débit plein tarif du wallet
 *   4. Créer l'abonnement actif (avec compensation/remboursement si l'insert échoue)
 *   5. Expirer les anciens abonnements actifs (un seul actif à la fois)
 *   6. Déclencher la commission d'affiliation (montant facturé > 0)
 */
router.post('/purchase', verifyJWT, subscriptionRateLimit, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const { plan_id, billing_cycle = 'monthly', payment_method = 'wallet' } = req.body || {};

    if (!plan_id) {
      res.status(400).json({ success: false, error: 'plan_id requis' });
      return;
    }
    const cycle: 'monthly' | 'quarterly' | 'yearly' =
      ['monthly', 'quarterly', 'yearly'].includes(billing_cycle) ? billing_cycle : 'monthly';

    // 1. Plan
    const { data: plan, error: planError } = await supabaseAdmin
      .from('plans')
      .select('id, name, display_name, monthly_price_gnf, yearly_price_gnf, is_active')
      .eq('id', plan_id)
      .eq('is_active', true)
      .single();

    if (planError || !plan) {
      res.status(404).json({ success: false, error: 'Plan non trouvé ou inactif' });
      return;
    }

    // 2. Prix selon le cycle
    const monthly = Number(plan.monthly_price_gnf) || 0;
    const price = cycle === 'yearly'
      ? (Number(plan.yearly_price_gnf) || monthly * 12)
      : cycle === 'quarterly' ? monthly * 3 : monthly;

    // 3. Période (calendaire)
    const now = new Date();
    const periodEnd = new Date(now);
    if (cycle === 'yearly') periodEnd.setFullYear(periodEnd.getFullYear() + 1);
    else if (cycle === 'quarterly') periodEnd.setMonth(periodEnd.getMonth() + 3);
    else periodEnd.setMonth(periodEnd.getMonth() + 1);

    const idempotencyKey = (req.headers['idempotency-key'] as string) || randomUUID();

    // 3-IDEMPOTENCE : si cette clé a déjà produit un abonnement, le renvoyer (anti double-traitement sur retry)
    const { data: replay } = await supabaseAdmin
      .from('subscriptions')
      .select('id, status')
      .eq('user_id', userId)
      .eq('metadata->>idempotency_key', idempotencyKey)
      .limit(1)
      .maybeSingle();
    if (replay) {
      res.status(200).json({ success: true, data: { subscription_id: replay.id, idempotent_replay: true } });
      return;
    }

    // 3bis. CHANGEMENT DE PLAN avant expiration (abonnement PAYANT actif non expiré)
    //   On DÉDUIT le montant déjà payé pour l'abonnement courant du prix du nouveau plan :
    //     montant à facturer = max(0, prix_nouveau_plan − montant_déjà_payé)
    //   - Upgrade (ex. Pro→Business) : l'utilisateur ne paie QUE la différence
    //   - Downgrade (ex. Premium→Business) : différence ≤ 0 → AUCUN débit (gratuit)
    //   La date de fin (current_period_end) est conservée dans tous les cas.
    const { data: currentSub } = await supabaseAdmin
      .from('subscriptions')
      .select('id, plan_id, price_paid_gnf, current_period_end, metadata, plans(name)')
      .eq('user_id', userId)
      .eq('status', 'active')
      .gt('price_paid_gnf', 0)
      .gt('current_period_end', now.toISOString())
      .order('current_period_end', { ascending: false })
      .limit(1)
      .maybeSingle();

    // Anti double-facturation : déjà abonné à CE plan et encore actif → aucun re-débit
    if (currentSub && currentSub.plan_id === plan_id) {
      res.status(200).json({
        success: true,
        data: { subscription_id: currentSub.id, already_active: true, end_date: currentSub.current_period_end },
        message: 'Vous êtes déjà abonné à ce plan (actif).',
      });
      return;
    }

    if (currentSub && currentSub.plan_id !== plan_id) {
      const currentPaid = Number(currentSub.price_paid_gnf) || 0;
      // Prix du nouveau plan MOINS le montant déjà payé (jamais négatif)
      const switchCharge = Math.max(0, Math.round(price - currentPaid));

      if (switchCharge > 0 && payment_method !== 'wallet') {
        res.status(400).json({ success: false, error: 'Seul le paiement par wallet est supporté' });
        return;
      }

      // ATOMIQUE : débit (différence) + mise à jour de l'abonnement en 1 transaction
      const switchMetadata = {
        ...((currentSub.metadata as any) || {}),
        idempotency_key: idempotencyKey,
        plan_changed_from: currentSub.plan_id,
        plan_changed_at: now.toISOString(),
        switch_charge_gnf: switchCharge,
        previous_paid_gnf: currentPaid,
        switch_type: switchCharge > 0 ? 'upgrade_difference' : 'downgrade_no_charge',
      };
      const { data: switchRpc, error: switchRpcErr } = await supabaseAdmin.rpc('purchase_vendor_subscription_atomic' as any, {
        p_user_id: userId,
        p_amount: switchCharge,
        p_idempotency_key: idempotencyKey,
        p_description: `Changement d'abonnement → ${plan.display_name} (différence après déduction de l'abonnement actuel)`,
        p_mode: 'switch',
        p_plan_id: plan_id,
        p_cycle: cycle,
        p_payment_method: payment_method,
        p_period_start: now.toISOString(),
        p_period_end: currentSub.current_period_end,
        p_auto_renew: true,
        p_metadata: switchMetadata,
        p_current_sub_id: currentSub.id,
      });
      if (switchRpcErr) {
        logger.error(`[subscriptions/purchase] switch RPC error: ${switchRpcErr.message}`);
        res.status(500).json({ success: false, error: 'Erreur lors du changement d\'abonnement' });
        return;
      }
      const switchResult = switchRpc as AtomicSubResult;
      if (switchResult.status === 'error') {
        const m = mapAtomicSubError(switchResult.error);
        logger.warn(`[subscriptions/purchase] switch refusé: ${switchResult.error}`);
        res.status(m.status).json({ success: false, error: m.message });
        return;
      }

      if (switchCharge > 0) {
        const commission = await triggerAffiliateCommission(userId, switchCharge, 'abonnement', currentSub.id);
        if (!commission.success) {
          logger.warn(`[subscriptions/purchase] commission switch non créée pour ${currentSub.id}: ${commission.error || 'unknown'}`);
        }
      }

      logger.info(`[subscriptions/purchase] CHANGEMENT user=${userId} → ${plan.name} | payé_avant=${currentPaid} prix_nouveau=${price} facturé=${switchCharge} GNF (${switchCharge > 0 ? 'upgrade: différence' : 'downgrade: gratuit'}) | période conservée jusqu'à ${currentSub.current_period_end}`);
      res.status(200).json({
        success: true,
        data: { subscription_id: switchResult.subscription_id || currentSub.id, plan_switch: true, charged_gnf: switchCharge },
      });
      return;
    }

    // 4. NOUVEL ABONNEMENT / renouvellement — ATOMIQUE (débit + insert en 1 transaction)
    const isFree = price <= 0;
    if (!isFree && payment_method !== 'wallet') {
      res.status(400).json({ success: false, error: 'Seul le paiement par wallet est supporté' });
      return;
    }

    const { data: newRpc, error: newRpcErr } = await supabaseAdmin.rpc('purchase_vendor_subscription_atomic' as any, {
      p_user_id: userId,
      p_amount: price,
      p_idempotency_key: idempotencyKey,
      p_description: `Abonnement ${plan.display_name} (${cycle})`,
      p_mode: 'new',
      p_plan_id: plan_id,
      p_cycle: cycle,
      p_payment_method: payment_method,
      p_period_start: now.toISOString(),
      p_period_end: periodEnd.toISOString(),
      p_auto_renew: !isFree,
      p_metadata: { initiated_from: 'backend_purchase', plan_name: plan.name, idempotency_key: idempotencyKey },
      p_current_sub_id: null,
    });
    if (newRpcErr) {
      logger.error(`[subscriptions/purchase] RPC error: ${newRpcErr.message}`);
      res.status(500).json({ success: false, error: 'Erreur lors de la création de l\'abonnement' });
      return;
    }
    const newResult = newRpc as AtomicSubResult;
    if (newResult.status === 'error') {
      const m = mapAtomicSubError(newResult.error);
      logger.warn(`[subscriptions/purchase] souscription refusée: ${newResult.error}`);
      res.status(m.status).json({ success: false, error: m.message });
      return;
    }

    // Commission d'affiliation (plans payants) — best-effort, hors transaction critique
    if (!isFree) {
      const commission = await triggerAffiliateCommission(userId, price, 'abonnement', newResult.subscription_id!);
      if (!commission.success) {
        logger.warn(`[subscriptions/purchase] commission non créée pour ${newResult.subscription_id}: ${commission.error || 'unknown'}`);
      }
    }

    logger.info(`[subscriptions/purchase] user=${userId} plan=${plan.name} cycle=${cycle} price=${price} GNF sub=${newResult.subscription_id}`);
    res.status(201).json({ success: true, data: { subscription_id: newResult.subscription_id } });
  } catch (error: any) {
    logger.error(`[subscriptions/purchase] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la souscription' });
  }
});

/**
 * POST /api/subscriptions/service/purchase
 *
 * Abonnement d'un SERVICE de proximité (scopé par professional_service_id) — backend Node.js.
 * Même modèle que le vendeur : débit wallet tracé, déduction au changement de plan
 * (max(0, prix_nouveau − déjà_payé)), période conservée lors d'un changement.
 * Tables : service_plans, service_subscriptions.
 */
router.post('/service/purchase', verifyJWT, subscriptionRateLimit, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const { service_id, plan_id, billing_cycle = 'monthly', payment_method = 'wallet' } = req.body || {};

    if (!service_id || !plan_id) {
      res.status(400).json({ success: false, error: 'service_id et plan_id requis' });
      return;
    }
    const cycle: 'monthly' | 'quarterly' | 'yearly' =
      ['monthly', 'quarterly', 'yearly'].includes(billing_cycle) ? billing_cycle : 'monthly';

    // 0. Vérifier que le service appartient à l'utilisateur
    const { data: svc } = await supabaseAdmin
      .from('professional_services')
      .select('id, user_id')
      .eq('id', service_id)
      .maybeSingle();
    if (!svc || svc.user_id !== userId) {
      res.status(403).json({ success: false, error: 'Service introuvable ou non autorisé' });
      return;
    }

    // 1. Plan
    const { data: plan, error: planError } = await supabaseAdmin
      .from('service_plans')
      .select('id, name, display_name, monthly_price_gnf, yearly_price_gnf, is_active')
      .eq('id', plan_id)
      .eq('is_active', true)
      .single();
    if (planError || !plan) {
      res.status(404).json({ success: false, error: 'Plan de service non trouvé ou inactif' });
      return;
    }

    // 2. Prix + période
    const monthly = Number(plan.monthly_price_gnf) || 0;
    const price = cycle === 'yearly'
      ? (Number(plan.yearly_price_gnf) || monthly * 12)
      : cycle === 'quarterly' ? monthly * 3 : monthly;
    const now = new Date();
    const periodEnd = new Date(now);
    if (cycle === 'yearly') periodEnd.setFullYear(periodEnd.getFullYear() + 1);
    else if (cycle === 'quarterly') periodEnd.setMonth(periodEnd.getMonth() + 3);
    else periodEnd.setMonth(periodEnd.getMonth() + 1);
    const idempotencyKey = (req.headers['idempotency-key'] as string) || randomUUID();

    // Idempotence : renvoyer l'abonnement déjà créé avec cette clé (anti retry)
    const { data: svcReplay } = await supabaseAdmin
      .from('service_subscriptions')
      .select('id')
      .eq('user_id', userId)
      .eq('professional_service_id', service_id)
      .eq('metadata->>idempotency_key', idempotencyKey)
      .limit(1)
      .maybeSingle();
    if (svcReplay) {
      res.status(200).json({ success: true, data: { subscription_id: svcReplay.id, idempotent_replay: true } });
      return;
    }

    // 3. Changement de plan avant expiration (pour CE service) — déduction du déjà payé
    const { data: currentSub } = await supabaseAdmin
      .from('service_subscriptions')
      .select('id, plan_id, price_paid_gnf, current_period_end, metadata')
      .eq('professional_service_id', service_id)
      .eq('user_id', userId)
      .eq('status', 'active')
      .gt('price_paid_gnf', 0)
      .gt('current_period_end', now.toISOString())
      .order('current_period_end', { ascending: false })
      .limit(1)
      .maybeSingle();

    // Anti double-facturation : déjà abonné à CE plan pour ce service et actif
    if (currentSub && currentSub.plan_id === plan_id) {
      res.status(200).json({
        success: true,
        data: { subscription_id: currentSub.id, already_active: true, end_date: currentSub.current_period_end },
        message: 'Ce service est déjà abonné à ce plan (actif).',
      });
      return;
    }

    if (currentSub && currentSub.plan_id !== plan_id) {
      const currentPaid = Number(currentSub.price_paid_gnf) || 0;
      const switchCharge = Math.max(0, Math.round(price - currentPaid));

      if (switchCharge > 0 && payment_method !== 'wallet') {
        res.status(400).json({ success: false, error: 'Seul le paiement par wallet est supporté' });
        return;
      }

      // ATOMIQUE : débit (différence) + mise à jour de l'abonnement service en 1 transaction
      const switchMetadata = {
        ...((currentSub.metadata as any) || {}),
        idempotency_key: idempotencyKey,
        plan_changed_from: currentSub.plan_id,
        plan_changed_at: now.toISOString(),
        switch_charge_gnf: switchCharge,
        previous_paid_gnf: currentPaid,
        switch_type: switchCharge > 0 ? 'upgrade_difference' : 'downgrade_no_charge',
      };
      const { data: switchRpc, error: switchRpcErr } = await supabaseAdmin.rpc('purchase_service_subscription_atomic' as any, {
        p_user_id: userId,
        p_amount: switchCharge,
        p_idempotency_key: idempotencyKey,
        p_description: `Changement abonnement service → ${plan.display_name}`,
        p_mode: 'switch',
        p_service_id: service_id,
        p_plan_id: plan_id,
        p_cycle: cycle,
        p_payment_method: payment_method,
        p_period_start: now.toISOString(),
        p_period_end: currentSub.current_period_end,
        p_auto_renew: true,
        p_metadata: switchMetadata,
        p_current_sub_id: currentSub.id,
      });
      if (switchRpcErr) {
        logger.error(`[subscriptions/service/purchase] switch RPC error: ${switchRpcErr.message}`);
        res.status(500).json({ success: false, error: 'Erreur lors du changement d\'abonnement' });
        return;
      }
      const switchResult = switchRpc as AtomicSubResult;
      if (switchResult.status === 'error') {
        const m = mapAtomicSubError(switchResult.error);
        logger.warn(`[subscriptions/service/purchase] switch refusé: ${switchResult.error}`);
        res.status(m.status).json({ success: false, error: m.message });
        return;
      }

      if (switchCharge > 0) {
        const commission = await triggerAffiliateCommission(userId, switchCharge, 'abonnement', currentSub.id);
        if (!commission.success) logger.warn(`[subscriptions/service/purchase] commission switch non créée: ${commission.error || 'unknown'}`);
      }

      logger.info(`[subscriptions/service/purchase] CHANGEMENT user=${userId} service=${service_id} → ${plan.name} | payé_avant=${currentPaid} prix=${price} facturé=${switchCharge} GNF`);
      res.status(200).json({ success: true, data: { subscription_id: switchResult.subscription_id || currentSub.id, plan_switch: true, charged_gnf: switchCharge } });
      return;
    }

    // 4. NOUVEL ABONNEMENT service / renouvellement — ATOMIQUE (débit + insert en 1 transaction)
    const isFree = price <= 0;
    if (!isFree && payment_method !== 'wallet') {
      res.status(400).json({ success: false, error: 'Seul le paiement par wallet est supporté' });
      return;
    }

    const { data: newRpc, error: newRpcErr } = await supabaseAdmin.rpc('purchase_service_subscription_atomic' as any, {
      p_user_id: userId,
      p_amount: price,
      p_idempotency_key: idempotencyKey,
      p_description: `Abonnement service ${plan.display_name} (${cycle})`,
      p_mode: 'new',
      p_service_id: service_id,
      p_plan_id: plan_id,
      p_cycle: cycle,
      p_payment_method: payment_method,
      p_period_start: now.toISOString(),
      p_period_end: periodEnd.toISOString(),
      p_auto_renew: !isFree,
      p_metadata: { initiated_from: 'backend_purchase', plan_name: plan.name, idempotency_key: idempotencyKey },
      p_current_sub_id: null,
    });
    if (newRpcErr) {
      logger.error(`[subscriptions/service/purchase] RPC error: ${newRpcErr.message}`);
      res.status(500).json({ success: false, error: 'Erreur lors de la création de l\'abonnement service' });
      return;
    }
    const newResult = newRpc as AtomicSubResult;
    if (newResult.status === 'error') {
      const m = mapAtomicSubError(newResult.error);
      logger.warn(`[subscriptions/service/purchase] souscription refusée: ${newResult.error}`);
      res.status(m.status).json({ success: false, error: m.message });
      return;
    }

    if (!isFree) {
      const commission = await triggerAffiliateCommission(userId, price, 'abonnement', newResult.subscription_id!);
      if (!commission.success) logger.warn(`[subscriptions/service/purchase] commission non créée: ${commission.error || 'unknown'}`);
    }

    logger.info(`[subscriptions/service/purchase] user=${userId} service=${service_id} plan=${plan.name} cycle=${cycle} price=${price} GNF sub=${newResult.subscription_id}`);
    res.status(201).json({ success: true, data: { subscription_id: newResult.subscription_id } });
  } catch (error: any) {
    logger.error(`[subscriptions/service/purchase] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la souscription au service' });
  }
});

/**
 * POST /api/subscriptions/driver/purchase
 *
 * Abonnement LIVREUR / TAXI (table driver_subscriptions, tarif unique depuis
 * driver_subscription_config) — backend Node.js.
 * - Débit wallet via debitWallet → tracé dans wallet_transactions (visible en historique,
 *   contrairement à l'ancienne RPC subscribe_driver qui écrivait dans `transactions`).
 * - Anti-double-facturation : si un abonnement est déjà actif et non expiré, on ne re-débite pas.
 */
router.post('/driver/purchase', verifyJWT, subscriptionRateLimit, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const { type = 'livreur', billing_cycle = 'monthly', payment_method = 'wallet' } = req.body || {};
    const driverType: 'taxi' | 'livreur' = ['taxi', 'livreur'].includes(type) ? type : 'livreur';
    const cycle: 'monthly' | 'yearly' = billing_cycle === 'yearly' ? 'yearly' : 'monthly';

    // 1. Config tarifaire (un seul tarif 'both')
    const { data: config } = await supabaseAdmin
      .from('driver_subscription_config')
      .select('price, duration_days, yearly_price')
      .eq('subscription_type', 'both')
      .eq('is_active', true)
      .order('updated_at', { ascending: false })
      .limit(1)
      .maybeSingle();

    const monthlyPrice = Number(config?.price) || 50000;
    const durationDays = Number(config?.duration_days) || 30;
    const price = cycle === 'yearly' ? (Number(config?.yearly_price) || monthlyPrice * 12) : monthlyPrice;
    const days = cycle === 'yearly' ? 365 : durationDays;

    const now = new Date();
    const endDate = new Date(now.getTime() + days * 86_400_000);
    const idempotencyKey = (req.headers['idempotency-key'] as string) || randomUUID();

    // Idempotence : renvoyer l'abonnement déjà créé avec cette clé (anti retry)
    const { data: drvReplay } = await supabaseAdmin
      .from('driver_subscriptions')
      .select('id')
      .eq('user_id', userId)
      .eq('metadata->>idempotency_key', idempotencyKey)
      .limit(1)
      .maybeSingle();
    if (drvReplay) {
      res.status(200).json({ success: true, data: { subscription_id: drvReplay.id, idempotent_replay: true } });
      return;
    }

    // 2. Anti-double-facturation : déjà un abonnement actif non expiré ?
    const { data: active } = await supabaseAdmin
      .from('driver_subscriptions')
      .select('id, type, end_date')
      .eq('user_id', userId)
      .eq('status', 'active')
      .gt('end_date', now.toISOString())
      .order('end_date', { ascending: false })
      .limit(1)
      .maybeSingle();

    if (active) {
      logger.info(`[subscriptions/driver/purchase] déjà actif user=${userId} jusqu'à ${active.end_date} — aucun débit`);
      res.status(200).json({
        success: true,
        data: { subscription_id: active.id, already_active: true, end_date: active.end_date },
        message: `Abonnement déjà actif jusqu'au ${active.end_date}`,
      });
      return;
    }

    const isFree = price <= 0;
    if (!isFree && payment_method !== 'wallet') {
      res.status(400).json({ success: false, error: 'Seul le paiement par wallet est supporté' });
      return;
    }

    const txCode = `SUB-${Date.now()}-${userId.slice(0, 8)}`;

    // ATOMIQUE : débit + expiration des anciens + insert nouvel abonnement (+ revenu) en 1 transaction
    const { data: drvRpc, error: drvRpcErr } = await supabaseAdmin.rpc('purchase_driver_subscription_atomic' as any, {
      p_user_id: userId,
      p_amount: price,
      p_idempotency_key: idempotencyKey,
      p_description: `Abonnement ${driverType} (${cycle})`,
      p_driver_type: driverType,
      p_cycle: cycle,
      p_payment_method: payment_method,
      p_start_date: now.toISOString(),
      p_end_date: endDate.toISOString(),
      p_transaction_id: txCode,
      p_metadata: { initiated_from: 'backend_purchase', idempotency_key: idempotencyKey },
    });
    if (drvRpcErr) {
      logger.error(`[subscriptions/driver/purchase] RPC error: ${drvRpcErr.message}`);
      res.status(500).json({ success: false, error: 'Erreur lors de la création de l\'abonnement' });
      return;
    }
    const drvResult = drvRpc as AtomicSubResult;
    if (drvResult.status === 'error') {
      const m = mapAtomicSubError(drvResult.error);
      logger.warn(`[subscriptions/driver/purchase] souscription refusée: ${drvResult.error}`);
      res.status(m.status).json({ success: false, error: m.message });
      return;
    }

    // Commission d'affiliation — best-effort, hors transaction critique
    if (!isFree) {
      const commission = await triggerAffiliateCommission(userId, price, 'abonnement', drvResult.subscription_id!);
      if (!commission.success) logger.warn(`[subscriptions/driver/purchase] commission non créée: ${commission.error || 'unknown'}`);
    }

    logger.info(`[subscriptions/driver/purchase] user=${userId} type=${driverType} cycle=${cycle} price=${price} GNF sub=${drvResult.subscription_id}`);
    res.status(201).json({ success: true, data: { subscription_id: drvResult.subscription_id } });
  } catch (error: any) {
    logger.error(`[subscriptions/driver/purchase] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la souscription' });
  }
});

/**
 * POST /api/subscriptions/confirm
 * Confirmer un abonnement après paiement validé.
 * Passe le statut de 'trialing' → 'active'.
 *
 * Vérifie que le trialing n'est pas expiré avant d'activer.
 */
router.post('/confirm', verifyJWT, subscriptionRateLimit, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const { subscription_id, payment_transaction_id } = req.body;

    if (!subscription_id) {
      res.status(400).json({ success: false, error: 'subscription_id requis' });
      return;
    }

    // Vérifier que l'abonnement existe et appartient à l'utilisateur
    const { data: subscription, error: fetchError } = await supabaseAdmin
      .from('subscriptions')
      .select('*')
      .eq('id', subscription_id)
      .eq('user_id', userId)
      .single();

    if (fetchError || !subscription) {
      res.status(404).json({ success: false, error: 'Abonnement non trouvé' });
      return;
    }

    if (subscription.status === 'active') {
      res.json({ success: true, message: 'Abonnement déjà actif', data: subscription });
      return;
    }

    if (subscription.status !== 'trialing') {
      res.status(400).json({
        success: false,
        error: `Impossible de confirmer un abonnement en statut "${subscription.status}"`
      });
      return;
    }

    // Vérifier que le trialing n'a pas expiré
    const trialEndsAt = (subscription as any).trial_ends_at;
    if (trialEndsAt && new Date(trialEndsAt) < new Date()) {
      // Marquer comme expiré
      await supabaseAdmin
        .from('subscriptions')
        .update({ status: 'expired', updated_at: new Date().toISOString() })
        .eq('id', subscription_id);

      res.status(410).json({
        success: false,
        error: 'Cet abonnement en attente a expiré. Veuillez souscrire à nouveau.'
      });
      return;
    }

    // Activer l'abonnement
    const { data: updated, error: updateError } = await supabaseAdmin
      .from('subscriptions')
      .update({
        status: 'active',
        payment_transaction_id: payment_transaction_id || null,
        updated_at: new Date().toISOString(),
        metadata: {
          ...((subscription.metadata as any) || {}),
          confirmed_at: new Date().toISOString(),
          confirmed_from: 'backend_v2',
          payment_transaction_id: payment_transaction_id || null,
        }
      })
      .eq('id', subscription_id)
      .select('*, plans(name, display_name)')
      .single();

    if (updateError) throw updateError;

    const pricePaid = Number(subscription.price_paid_gnf || updated.price_paid_gnf || 0);
    if (pricePaid > 0) {
      const commissionResult = await triggerAffiliateCommission(
        userId,
        pricePaid,
        'abonnement',
        subscription_id
      );

      if (!commissionResult.success) {
        logger.warn(`Agent commission not credited for subscription ${subscription_id}: ${commissionResult.error || 'unknown error'}`);
      }
    }

    logger.info(`Subscription confirmed: ${subscription_id} for user ${userId}`);
    res.json({ success: true, data: updated });
  } catch (error: any) {
    logger.error(`Error confirming subscription: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la confirmation' });
  }
});

/**
 * POST /api/subscriptions/expire-stale
 *
 * Nettoyage des abonnements fantômes :
 * Passe en 'expired' tous les abonnements en 'trialing' dont le trial_ends_at est dépassé.
 *
 * À appeler via cron ou manuellement (protégé par auth admin/interne).
 */
router.post('/expire-stale', verifyJWT, requireRole(['admin']), async (_req: AuthenticatedRequest, res: Response) => {
  try {
    const now = new Date().toISOString();

    const { data, error, count } = await supabaseAdmin
      .from('subscriptions')
      .update({
        status: 'expired',
        updated_at: now,
        metadata: { expired_reason: 'trialing_not_confirmed', expired_by: 'system_cleanup' }
      })
      .eq('status', 'trialing')
      .lt('trial_ends_at', now)
      .select('id, user_id');

    if (error) throw error;

    const expiredCount = data?.length || 0;
    logger.info(`Expired ${expiredCount} stale trialing subscriptions`);

    res.json({
      success: true,
      expired_count: expiredCount,
      expired_ids: data?.map(s => s.id) || []
    });
  } catch (error: any) {
    logger.error(`Error expiring stale subscriptions: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors du nettoyage' });
  }
});

/**
 * POST /api/subscriptions/cancel
 * Annuler un abonnement — statut → 'cancelled'
 */
router.post('/cancel', verifyJWT, subscriptionRateLimit, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;

    const { data: subscription, error: fetchError } = await supabaseAdmin
      .from('subscriptions')
      .select('*')
      .eq('user_id', userId)
      .in('status', ['active', 'trialing'])
      .order('created_at', { ascending: false })
      .limit(1)
      .single();

    if (fetchError || !subscription) {
      res.status(404).json({ success: false, error: 'Aucun abonnement actif' });
      return;
    }

    const { error: updateError } = await supabaseAdmin
      .from('subscriptions')
      .update({
        status: 'cancelled',
        auto_renew: false,
        updated_at: new Date().toISOString(),
        metadata: {
          ...((subscription.metadata as any) || {}),
          cancelled_at: new Date().toISOString(),
          cancelled_from: 'backend_v2'
        }
      })
      .eq('id', subscription.id);

    if (updateError) throw updateError;

    logger.info(`Subscription cancelled: ${subscription.id} for user ${userId}`);
    res.json({ success: true, message: 'Abonnement annulé' });
  } catch (error: any) {
    logger.error(`Error canceling subscription: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de l\'annulation' });
  }
});

/**
 * GET /api/subscriptions/limits
 * Vérifie les limites du plan actuel (produits, images, fonctionnalités).
 *
 * Fallback : si aucun abonnement actif, retourne les limites du plan gratuit
 * alignées avec la table `plans` (free: max_products=10, max_images=3).
 */
router.get('/limits', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;

    const { data: sub, error } = await supabaseAdmin
      .from('subscriptions')
      .select('plans(max_products, max_images_per_product, analytics_access, priority_support, featured_products, api_access, custom_branding)')
      .eq('user_id', userId)
      .in('status', ['active', 'trialing'])
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();

    if (error) throw error;

    if (!sub || !sub.plans) {
      // Charger les limites du plan gratuit depuis la DB
      await loadFreePlanFallback();
      res.json({
        success: true,
        data: FREE_PLAN_FALLBACK,
        has_subscription: false
      });
      return;
    }

    res.json({ success: true, data: sub.plans, has_subscription: true });
  } catch (error: any) {
    logger.error(`Error fetching limits: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur' });
  }
});

export default router;
