import { Router, Response } from 'express';
import { z } from 'zod';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import { requirePermissionOrRole } from '../middlewares/permissions.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import {
  rankMarketplaceCandidates,
  getVendorVisibilitySummary,
  getVisibilityAdminOverview,
} from '../services/marketplaceVisibility.service.js';
import type { VisibilityCandidate } from '../services/marketplaceVisibility.service.js';
import { emitCoreFeatureEvent } from '../services/coreFeatureEvents.service.js';

const router = Router();

const CandidateSchema = z.object({
  id: z.string().uuid(),
  itemType: z.enum(['product', 'digital_product', 'professional_service']),
  vendorId: z.string().uuid().nullable().optional(),
  vendorUserId: z.string().uuid().nullable().optional(),
  rating: z.number().nullable().optional(),
  reviewsCount: z.number().nullable().optional(),
  createdAt: z.string().nullable().optional(),
  descriptionLength: z.number().nullable().optional(),
  imageCount: z.number().nullable().optional(),
  isSponsored: z.boolean().nullable().optional(),
});

const RankPayloadSchema = z.object({
  items: z.array(CandidateSchema).max(500),
  context: z.record(z.string(), z.any()).optional(),
});

const BoostPayloadSchema = z.object({
  targetType: z.enum(['product', 'shop']),
  targetId: z.string().uuid(),
  placement: z.enum(['general', 'homepage', 'category', 'search']).default('general'),
  categorySlug: z.string().max(100).optional(),
  budgetAmount: z.number().min(0),
  amountPaid: z.number().min(0).default(0),
  boostScore: z.number().min(0).max(100),
  startsAt: z.string().optional(),
  endsAt: z.string().optional(),
  paymentReference: z.string().max(255).optional(),
  activateNow: z.boolean().default(false),
  metadata: z.record(z.string(), z.any()).optional(),
});

const ConfigPayloadSchema = z.object({
  subscription_weight: z.number().min(0).max(100),
  performance_weight: z.number().min(0).max(100),
  boost_weight: z.number().min(0).max(100),
  quality_weight: z.number().min(0).max(100),
  relevance_weight: z.number().min(0).max(100),
  sponsored_slots_ratio: z.number().min(0).max(100),
  popular_slots_ratio: z.number().min(0).max(100),
  organic_slots_ratio: z.number().min(0).max(100),
  max_boost_per_vendor: z.number().int().min(1).max(100),
  vendor_diversity_penalty: z.number().min(0).max(100),
  min_quality_threshold: z.number().min(0).max(100),
  rotation_factor: z.number().min(0).max(30),
});

const PlanScorePayloadSchema = z.object({
  planName: z.string().min(1).max(100),
  visibilityTier: z.string().min(1).max(100),
  baseScore: z.number().min(0).max(100),
  exposureMultiplier: z.number().min(0.1).max(5).default(1),
  frequencyBoost: z.number().min(0.1).max(5).default(1),
});

// Public endpoint for marketplace listing ranking
router.post('/rank-candidates', async (req, res: Response) => {
  try {
    const parsed = RankPayloadSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ success: false, error: 'Payload invalide', details: parsed.error.flatten() });
      return;
    }

    const result = await rankMarketplaceCandidates(parsed.data.items as VisibilityCandidate[], parsed.data.context);
    await emitCoreFeatureEvent({
      featureKey: 'marketplace.ranking',
      coreEngine: 'commerce',
      ownerModule: 'marketplace_visibility',
      criticality: 'high',
      status: 'success',
      payload: { items_count: parsed.data.items.length },
    });
    res.json(result);
  } catch (error: any) {
    logger.error(`[Visibility] rank-candidates error: ${error.message}`);
    await emitCoreFeatureEvent({
      featureKey: 'marketplace.ranking',
      coreEngine: 'commerce',
      ownerModule: 'marketplace_visibility',
      criticality: 'high',
      status: 'failure',
      payload: { error: error.message },
    });
    res.status(500).json({ success: false, error: 'Erreur de ranking' });
  }
});

// Vendor summary
router.get('/vendor/me', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const summary = await getVendorVisibilitySummary(userId);
    res.json({ success: true, data: summary });
  } catch (error: any) {
    logger.error(`[Visibility] vendor summary error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur résumé visibilité' });
  }
});

// Vendor boosts list
router.get('/vendor/boosts', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin
      .from('marketplace_visibility_boosts')
      .select('*')
      .eq('owner_user_id', req.user!.id)
      .order('created_at', { ascending: false });

    if (error) throw error;

    res.json({ success: true, data: data || [] });
  } catch (error: any) {
    logger.error(`[Visibility] vendor boosts error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur chargement boosts' });
  }
});

// Vendor creates boost request
router.post('/vendor/boosts', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const parsed = BoostPayloadSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ success: false, error: 'Payload boost invalide', details: parsed.error.flatten() });
      return;
    }

    const payload = parsed.data;
    const now = new Date();
    const startsAt = payload.startsAt ? new Date(payload.startsAt) : now;
    const endsAt = payload.endsAt ? new Date(payload.endsAt) : new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000);

    if (Number.isNaN(startsAt.getTime()) || Number.isNaN(endsAt.getTime()) || endsAt <= startsAt) {
      res.status(400).json({ success: false, error: 'Fenêtre temporelle invalide' });
      return;
    }

    const status = payload.activateNow ? 'active' : 'pending';

    const { data, error } = await supabaseAdmin
      .from('marketplace_visibility_boosts')
      .insert({
        owner_user_id: req.user!.id,
        target_type: payload.targetType,
        target_id: payload.targetId,
        placement: payload.placement,
        category_slug: payload.categorySlug || null,
        status,
        budget_amount: payload.budgetAmount,
        amount_paid: payload.amountPaid,
        boost_score: payload.boostScore,
        starts_at: startsAt.toISOString(),
        ends_at: endsAt.toISOString(),
        payment_reference: payload.paymentReference || null,
        metadata: payload.metadata || {},
        created_by: req.user!.id,
        updated_by: req.user!.id,
      })
      .select('*')
      .single();

    if (error) throw error;

    await emitCoreFeatureEvent({
      featureKey: 'marketplace.boost.create',
      coreEngine: 'commerce',
      ownerModule: 'marketplace_visibility',
      criticality: 'high',
      status: 'success',
      userId: req.user!.id,
      payload: { boost_id: (data as any)?.id, status },
    });

    res.status(201).json({ success: true, data, message: status === 'pending' ? 'Boost créé en attente de validation' : 'Boost activé' });
  } catch (error: any) {
    logger.error(`[Visibility] create boost error: ${error.message}`);
    await emitCoreFeatureEvent({
      featureKey: 'marketplace.boost.create',
      coreEngine: 'commerce',
      ownerModule: 'marketplace_visibility',
      criticality: 'high',
      status: 'failure',
      userId: req.user?.id || null,
      payload: { error: error.message },
    });
    res.status(500).json({ success: false, error: 'Erreur création boost' });
  }
});

// PDG/Admin overview
router.get(
  '/pdg/overview',
  verifyJWT,
  requirePermissionOrRole({ permissionKey: 'manage_marketplace_visibility', allowedRoles: ['admin', 'pdg', 'ceo'] }),
  async (_req: AuthenticatedRequest, res: Response) => {
  try {
    const overview = await getVisibilityAdminOverview();
    res.json({ success: true, data: overview });
  } catch (error: any) {
    logger.error(`[Visibility] pdg overview error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur cockpit visibilité' });
  }
});

// PDG/Admin config update
router.put(
  '/pdg/config',
  verifyJWT,
  requirePermissionOrRole({ permissionKey: 'manage_marketplace_visibility', allowedRoles: ['admin', 'pdg', 'ceo'] }),
  async (req: AuthenticatedRequest, res: Response) => {
  try {
    const parsed = ConfigPayloadSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ success: false, error: 'Configuration invalide', details: parsed.error.flatten() });
      return;
    }

    const total =
      parsed.data.subscription_weight +
      parsed.data.performance_weight +
      parsed.data.boost_weight +
      parsed.data.quality_weight +
      parsed.data.relevance_weight;

    if (Math.abs(total - 100) > 0.01) {
      res.status(400).json({ success: false, error: 'Les poids doivent totaliser 100%' });
      return;
    }

    const { data, error } = await supabaseAdmin
      .from('marketplace_visibility_settings')
      .upsert(
        {
          config_name: 'default',
          ...parsed.data,
          is_active: true,
          updated_by: req.user!.id,
          created_by: req.user!.id,
        },
        { onConflict: 'config_name' }
      )
      .select('*')
      .single();

    if (error) throw error;

    res.json({ success: true, data });
  } catch (error: any) {
    logger.error(`[Visibility] update config error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur mise à jour configuration' });
  }
});

// PDG/Admin plan score update
router.put(
  '/pdg/plan-score',
  verifyJWT,
  requirePermissionOrRole({ permissionKey: 'manage_marketplace_visibility', allowedRoles: ['admin', 'pdg', 'ceo'] }),
  async (req: AuthenticatedRequest, res: Response) => {
  try {
    const parsed = PlanScorePayloadSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ success: false, error: 'Payload plan score invalide', details: parsed.error.flatten() });
      return;
    }

    const body = parsed.data;

    const { data, error } = await supabaseAdmin
      .from('marketplace_visibility_plan_scores')
      .upsert(
        {
          plan_name: body.planName.toLowerCase().trim(),
          visibility_tier: body.visibilityTier,
          base_score: body.baseScore,
          exposure_multiplier: body.exposureMultiplier,
          frequency_boost: body.frequencyBoost,
          updated_by: req.user!.id,
          created_by: req.user!.id,
        },
        { onConflict: 'plan_name' }
      )
      .select('*')
      .single();

    if (error) throw error;

    res.json({ success: true, data });
  } catch (error: any) {
    logger.error(`[Visibility] update plan score error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur mise à jour plan score' });
  }
});

// PDG/Admin boost moderation
router.patch(
  '/pdg/boosts/:boostId/status',
  verifyJWT,
  requirePermissionOrRole({ permissionKey: 'manage_marketplace_visibility', allowedRoles: ['admin', 'pdg', 'ceo'] }),
  async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { boostId } = req.params;
    const status = String(req.body?.status || '').trim();

    if (!['pending', 'active', 'paused', 'expired', 'cancelled'].includes(status)) {
      res.status(400).json({ success: false, error: 'Statut invalide' });
      return;
    }

    const { data, error } = await supabaseAdmin
      .from('marketplace_visibility_boosts')
      .update({ status, updated_by: req.user!.id })
      .eq('id', boostId)
      .select('*')
      .single();

    if (error) throw error;

    res.json({ success: true, data });
  } catch (error: any) {
    logger.error(`[Visibility] update boost status error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur mise à jour boost' });
  }
});

export default router;
