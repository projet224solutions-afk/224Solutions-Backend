/**
 * 🤝 AFFILIATE ROUTES - Backend Node.js centralisé
 *
 * Endpoints gérés ici :
 *   - POST /api/affiliate/register       : enregistrement avec token d'affiliation (migré depuis register-with-affiliate Edge Function)
 *   - POST /api/affiliate/commission     : déclenchement manuel de commission (admin/interne)
 *   - GET  /api/affiliate/stats          : statistiques d'affiliation pour l'utilisateur connecté
 *
 * Migration :
 *   - register-with-affiliate (Edge Function) → /api/affiliate/register
 */

import { Router, Request, Response } from 'express';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { auditTrail } from '../services/auditTrail.service.js';
import { verifyJWT, optionalJWT } from '../middlewares/auth.middleware.js';
import { requirePermissionOrRole } from '../middlewares/permissions.middleware.js';
import { triggerAffiliateCommission } from '../services/commission.service.js';

const router = Router();

// ─────────────────────────────────────────────────────────
// POST /api/affiliate/register
// Enregistrement avec token d'affiliation
// Migré depuis register-with-affiliate Edge Function (223 lignes)
// ─────────────────────────────────────────────────────────

/**
 * POST /api/affiliate/register
 * Corps : { userId, affiliateToken, deviceFingerprint?, ipAddress? }
 * Associe un utilisateur nouvellement créé à un affilié.
 * Anti-abus : empêche l'auto-affiliation, limite les inscriptions par IP.
 */
router.post('/register', optionalJWT, async (req: Request, res: Response) => {
  const { userId, affiliateToken, deviceFingerprint, ipAddress } = req.body;

  if (!userId || !affiliateToken) {
    res.status(400).json({ success: false, error: 'userId et affiliateToken requis' });
    return;
  }

  const authenticatedUserId = (req as any).user?.id;
  if (authenticatedUserId && authenticatedUserId !== userId) {
    res.status(403).json({ success: false, error: 'userId ne correspond pas à l\'utilisateur connecté' });
    return;
  }

  // Valider le token d'affiliation
  const { data: affiliateLink, error: linkError } = await supabaseAdmin
    .from('affiliate_links')
    .select('id, affiliate_user_id, campaign, max_uses, use_count, expires_at, is_active')
    .eq('token', affiliateToken)
    .maybeSingle();

  if (linkError || !affiliateLink) {
    res.status(404).json({ success: false, error: 'Token d\'affiliation invalide' });
    return;
  }

  if (!affiliateLink.is_active) {
    res.status(400).json({ success: false, error: 'Lien d\'affiliation inactif' });
    return;
  }

  if (affiliateLink.expires_at && new Date(affiliateLink.expires_at) < new Date()) {
    res.status(400).json({ success: false, error: 'Lien d\'affiliation expiré' });
    return;
  }

  if (affiliateLink.max_uses && affiliateLink.use_count >= affiliateLink.max_uses) {
    res.status(400).json({ success: false, error: 'Lien d\'affiliation épuisé' });
    return;
  }

  // Anti-auto-affiliation
  if (affiliateLink.affiliate_user_id === userId) {
    res.status(400).json({ success: false, error: 'Auto-affiliation interdite' });
    return;
  }

  // Vérifier que l'utilisateur n'est pas déjà affilié
  const { data: existingAffilitation } = await supabaseAdmin
    .from('user_agent_affiliations')
    .select('id')
    .eq('user_id', userId)
    .maybeSingle();

  if (existingAffilitation) {
    res.status(409).json({ success: false, error: 'Utilisateur déjà affilié' });
    return;
  }

  // Anti-abus IP : max 5 inscriptions affiliées par IP sur 24h
  if (ipAddress) {
    const oneDayAgo = new Date(Date.now() - 86400000).toISOString();
    const { count: ipCount } = await supabaseAdmin
      .from('user_agent_affiliations')
      .select('id', { count: 'exact', head: true })
      .eq('registration_ip', ipAddress)
      .gte('created_at', oneDayAgo);

    if ((ipCount || 0) >= 5) {
      logger.warn(`[AffiliateRegister] IP abuse detected: ${ipAddress}`);
      void Promise.resolve(supabaseAdmin.from('financial_security_alerts').insert({
        alert_type: 'AFFILIATE_IP_ABUSE', severity: 'medium',
        details: { ip: ipAddress, userId, affiliateToken },
      })).catch(() => {});
      res.status(429).json({ success: false, error: 'Trop d\'inscriptions depuis cette IP' });
      return;
    }
  }

  // Créer l'affiliation
  const { error: affiliationError } = await supabaseAdmin
    .from('user_agent_affiliations')
    .insert({
      user_id: userId,
      agent_id: affiliateLink.affiliate_user_id,
      affiliate_link_id: affiliateLink.id,
      campaign: affiliateLink.campaign,
      registration_ip: ipAddress || null,
      device_fingerprint: deviceFingerprint || null,
      status: 'active',
    });

  if (affiliationError) {
    logger.error('[AffiliateRegister] Failed to create affiliation', affiliationError);
    res.status(500).json({ success: false, error: 'Erreur lors de l\'enregistrement de l\'affiliation' });
    return;
  }

  // Incrémenter le compteur d'utilisation du lien
  void Promise.resolve(
    supabaseAdmin.from('affiliate_links')
      .update({ use_count: (affiliateLink.use_count || 0) + 1 })
      .eq('id', affiliateLink.id)
  ).catch(() => {});

  await auditTrail.log({
    actorId: userId, actorType: 'user', action: 'affiliate.register',
    resourceType: 'user_agent_affiliations', resourceId: affiliateLink.id,
    metadata: { affiliateUserId: affiliateLink.affiliate_user_id, campaign: affiliateLink.campaign },
    riskLevel: 'low',
  });

  logger.info(`[AffiliateRegister] User ${userId} affiliated to ${affiliateLink.affiliate_user_id}`);
  res.status(201).json({ success: true, message: 'Affiliation enregistrée avec succès' });
});

// ─────────────────────────────────────────────────────────
// POST /api/affiliate/commission
// Déclencher une commission manuellement (admin ou appel interne)
// ─────────────────────────────────────────────────────────

/**
 * POST /api/affiliate/commission
 * Corps : { userId, amount, transactionType, transactionId? }
 * Réservé aux admins et aux appels internes (X-Internal-API-Key).
 */
router.post(
  '/commission',
  optionalJWT,
  requirePermissionOrRole({
    permissionKey: 'manage_commissions',
    allowInternalApiKey: true,
    allowedRoles: ['admin', 'pdg', 'ceo'],
  }),
  async (req: Request, res: Response) => {
  const user = (req as any).user;
  const internalKey = req.headers['x-internal-api-key'] as string;
  const configuredInternalKey = process.env.INTERNAL_API_KEY;
  const isInternal = !!configuredInternalKey && internalKey === configuredInternalKey;

  const { userId, amount, transactionType, transactionId } = req.body;

  if (!userId || !amount || !transactionType) {
    res.status(400).json({ success: false, error: 'userId, amount et transactionType requis' });
    return;
  }

  if (typeof amount !== 'number' || amount <= 0) {
    res.status(400).json({ success: false, error: 'Montant invalide' });
    return;
  }

  // Anti-exploit: limiter les montants de commission manuels
  const MAX_COMMISSION_AMOUNT = 100000000; // 100M GNF max par transaction
  if (amount > MAX_COMMISSION_AMOUNT) {
    logger.warn(`[Affiliate] Commission amount exceeds limit: ${amount}`);
    res.status(400).json({ success: false, error: `Montant max ${MAX_COMMISSION_AMOUNT} GNF` });
    return;
  }

  await triggerAffiliateCommission(userId, amount, transactionType, transactionId);

  await auditTrail.log({
    actorId: user?.id || 'internal', actorType: isInternal ? 'system' : 'admin',
    action: 'affiliate.commission.manual', resourceType: 'commission', resourceId: transactionId || userId,
    metadata: { targetUserId: userId, amount, transactionType },
    riskLevel: 'medium',
  });

  res.json({ success: true, message: 'Commission déclenchée avec succès' });
});

// ─────────────────────────────────────────────────────────
// GET /api/affiliate/stats
// Statistiques d'affiliation pour l'utilisateur connecté
// ─────────────────────────────────────────────────────────

/**
 * GET /api/affiliate/stats
 * Retourne les stats d'affiliation : parrainages, commissions, liens.
 */
router.get('/stats', verifyJWT, async (req: Request, res: Response) => {
  const user = (req as any).user;

  const [affiliationsResult, commissionsResult, linksResult] = await Promise.all([
    supabaseAdmin.from('user_agent_affiliations').select('id, created_at, status')
      .eq('agent_id', user.id),
    supabaseAdmin.from('agent_commissions_log').select('amount, created_at, transaction_type, status')
      .eq('agent_id', user.id).order('created_at', { ascending: false }).limit(50),
    supabaseAdmin.from('affiliate_links').select('id, token, campaign, use_count, max_uses, expires_at, is_active, created_at')
      .eq('affiliate_user_id', user.id),
  ]);

  const commissions = commissionsResult.data || [];
  const totalCommissionsEarned = commissions
    .filter(c => c.status === 'paid' || c.status === 'credited')
    .reduce((sum, c) => sum + Number(c.amount || 0), 0);

  res.json({
    success: true,
    data: {
      totalReferrals: affiliationsResult.data?.length || 0,
      recentReferrals: (affiliationsResult.data || []).slice(0, 10),
      totalCommissionsEarned,
      recentCommissions: commissions.slice(0, 10),
      affiliateLinks: linksResult.data || [],
    },
  });
});

export default router;
