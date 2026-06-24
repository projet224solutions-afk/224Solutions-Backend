import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

export type VisibilityItemType = 'product' | 'digital_product' | 'professional_service';

export interface VisibilityCandidate {
  id: string;
  itemType: VisibilityItemType;
  vendorId?: string | null;
  vendorUserId?: string | null;
  rating?: number | null;
  reviewsCount?: number | null;
  createdAt?: string | null;
  descriptionLength?: number | null;
  imageCount?: number | null;
  isSponsored?: boolean | null;
}

interface RankingConfig {
  subscription_weight: number;
  performance_weight: number;
  boost_weight: number;
  quality_weight: number;
  relevance_weight: number;
  vendor_diversity_penalty: number;
  min_quality_threshold: number;
  rotation_factor: number;
  // ✅ AJOUTS — colonnes additives de la migration
  new_vendor_bonus_days: number;
  new_vendor_max_bonus: number;
  trend_weight: number;
  trend_window_hours: number;
  low_stock_threshold: number;
  low_stock_penalty: number;
}

interface ScoredItem {
  id: string;
  itemType: VisibilityItemType;
  vendorUserId: string | null;
  subscriptionScore: number;
  performanceScore: number;
  boostScore: number;
  qualityScore: number;
  relevanceScore: number;
  finalScore: number;
  // ✅ AJOUTS — nouvelles composantes du score
  trendBonus: number;
  newVendorBonus: number;
  reliabilityPenalty: number;
  lowStockPenalty: number;
  categoryBonus: number;
  breakdown: Record<string, number | string | null>;
}

const DEFAULT_PLAN_SCORES: Record<string, number> = {
  free: 30,
  basic: 35,
  pro: 60,
  premium: 80,
  elite: 95,
};

const DEFAULT_CONFIG: RankingConfig = {
  subscription_weight: 35,
  performance_weight: 25,
  boost_weight: 20,
  quality_weight: 10,
  relevance_weight: 10,
  vendor_diversity_penalty: 8,
  min_quality_threshold: 20,
  rotation_factor: 10,
  // ✅ AJOUTS — fallback si les colonnes SQL ne sont pas encore présentes
  new_vendor_bonus_days: 30,
  new_vendor_max_bonus: 30,
  trend_weight: 15,
  trend_window_hours: 24,
  low_stock_threshold: 3,
  low_stock_penalty: 5,
};

function clamp(value: number, min = 0, max = 100): number {
  return Math.max(min, Math.min(max, value));
}

function normalizeRatio(value: number, maxValue: number): number {
  if (!maxValue || maxValue <= 0) return 0;
  return clamp((value / maxValue) * 100);
}

function parseDateOrNow(date: string | null | undefined): Date {
  if (!date) return new Date();
  const parsed = new Date(date);
  return Number.isNaN(parsed.getTime()) ? new Date() : parsed;
}

function relevanceFromRecency(createdAt: string | null | undefined, rotationFactor: number): number {
  const now = Date.now();
  const createdMs = parseDateOrNow(createdAt).getTime();
  const ageDays = Math.max(0, Math.floor((now - createdMs) / 86_400_000));

  // ✅ Fraîcheur logarithmique : jamais 0, déclin lent après le 1er mois
  // Jour 0→100 · 7→~83 · 30→~68 · 90→~50 · 365→~35
  const recencyScore = clamp(100 / (1 + Math.log10(ageDays + 1) * 2));
  const daySeed = new Date().toISOString().slice(0, 10);
  const hashInput = `${createdAt || 'n/a'}:${daySeed}`;
  let hash = 0;
  for (let i = 0; i < hashInput.length; i++) {
    hash = ((hash << 5) - hash + hashInput.charCodeAt(i)) | 0;
  }
  const rotationJitter = ((Math.abs(hash) % 100) / 100) * clamp(rotationFactor, 0, 30);

  return clamp(recencyScore + rotationJitter);
}

async function getConfig(): Promise<RankingConfig> {
  const { data, error } = await supabaseAdmin
    .from('marketplace_visibility_settings')
    .select('subscription_weight, performance_weight, boost_weight, quality_weight, relevance_weight, vendor_diversity_penalty, min_quality_threshold, rotation_factor, new_vendor_bonus_days, new_vendor_max_bonus, trend_weight, trend_window_hours, low_stock_threshold, low_stock_penalty')
    .eq('is_active', true)
    .order('updated_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  if (error) {
    logger.warn(`[Visibility] Failed to load config: ${error.message}`);
    return DEFAULT_CONFIG;
  }

  if (!data) return DEFAULT_CONFIG;

  return {
    subscription_weight: Number(data.subscription_weight ?? DEFAULT_CONFIG.subscription_weight),
    performance_weight: Number(data.performance_weight ?? DEFAULT_CONFIG.performance_weight),
    boost_weight: Number(data.boost_weight ?? DEFAULT_CONFIG.boost_weight),
    quality_weight: Number(data.quality_weight ?? DEFAULT_CONFIG.quality_weight),
    relevance_weight: Number(data.relevance_weight ?? DEFAULT_CONFIG.relevance_weight),
    vendor_diversity_penalty: Number(data.vendor_diversity_penalty ?? DEFAULT_CONFIG.vendor_diversity_penalty),
    min_quality_threshold: Number(data.min_quality_threshold ?? DEFAULT_CONFIG.min_quality_threshold),
    rotation_factor: Number(data.rotation_factor ?? DEFAULT_CONFIG.rotation_factor),
    // ✅ AJOUTS
    new_vendor_bonus_days: Number((data as any).new_vendor_bonus_days ?? DEFAULT_CONFIG.new_vendor_bonus_days),
    new_vendor_max_bonus: Number((data as any).new_vendor_max_bonus ?? DEFAULT_CONFIG.new_vendor_max_bonus),
    trend_weight: Number((data as any).trend_weight ?? DEFAULT_CONFIG.trend_weight),
    trend_window_hours: Number((data as any).trend_window_hours ?? DEFAULT_CONFIG.trend_window_hours),
    low_stock_threshold: Number((data as any).low_stock_threshold ?? DEFAULT_CONFIG.low_stock_threshold),
    low_stock_penalty: Number((data as any).low_stock_penalty ?? DEFAULT_CONFIG.low_stock_penalty),
  };
}

async function getPlanScoresMap(): Promise<Record<string, number>> {
  const { data, error } = await supabaseAdmin
    .from('marketplace_visibility_plan_scores')
    .select('plan_name, base_score');

  if (error || !data?.length) {
    if (error) logger.warn(`[Visibility] Failed to load plan scores: ${error.message}`);
    return DEFAULT_PLAN_SCORES;
  }

  const mapped: Record<string, number> = { ...DEFAULT_PLAN_SCORES };
  for (const row of data) {
    const key = String((row as any).plan_name || '').toLowerCase().trim();
    if (!key) continue;
    mapped[key] = Number((row as any).base_score || DEFAULT_PLAN_SCORES[key] || 30);
  }
  return mapped;
}

async function getVendorPlanMap(vendorUserIds: string[]): Promise<Record<string, string>> {
  if (!vendorUserIds.length) return {};

  const { data, error } = await supabaseAdmin
    .from('subscriptions')
    .select('user_id, created_at, plans(name)')
    .in('user_id', vendorUserIds)
    .in('status', ['active', 'trialing'])
    .order('created_at', { ascending: false });

  if (error) {
    logger.warn(`[Visibility] Failed to load vendor subscriptions: ${error.message}`);
    return {};
  }

  const result: Record<string, string> = {};
  for (const row of data || []) {
    const userId = (row as any).user_id as string;
    if (!userId || result[userId]) continue;
    const planName = String((row as any).plans?.name || 'free').toLowerCase();
    result[userId] = planName;
  }
  return result;
}

// ✅ NOUVEAU : date de création de chaque vendeur (bonus nouveau vendeur)
async function getVendorCreationMap(vendorUserIds: string[]): Promise<Map<string, Date>> {
  if (!vendorUserIds.length) return new Map();
  const { data, error } = await supabaseAdmin
    .from('vendors')
    .select('user_id, created_at')
    .in('user_id', vendorUserIds);
  if (error) {
    logger.warn(`[Visibility] Vendor creation dates error: ${error.message}`);
    return new Map();
  }
  const result = new Map<string, Date>();
  for (const row of data || []) {
    const uid = (row as any).user_id as string;
    const d = (row as any).created_at;
    if (uid && d) result.set(uid, new Date(d));
  }
  return result;
}

// ✅ NOUVEAU : score tendance par produit (vues + paniers + achats des N dernières heures)
async function getTrendScoreMap(
  candidates: VisibilityCandidate[],
  windowHours: number
): Promise<Map<string, number>> {
  if (!candidates.length) return new Map();
  const productIds = candidates.map(c => c.id);
  const since = new Date(Date.now() - windowHours * 3_600_000).toISOString();

  const { data, error } = await supabaseAdmin
    .from('product_trend_signals')
    .select('product_id, signal_type')
    .in('product_id', productIds)
    .gte('created_at', since);

  if (error) {
    logger.warn(`[Visibility] Trend signals error (non-blocking): ${error.message}`);
    return new Map();
  }

  const SIGNAL_WEIGHTS: Record<string, number> = { view: 0.3, add_to_cart: 0.5, purchase: 1.0 };
  const raw = new Map<string, number>();
  for (const row of data || []) {
    const pid = (row as any).product_id as string;
    const w = SIGNAL_WEIGHTS[(row as any).signal_type] ?? 0;
    raw.set(pid, (raw.get(pid) || 0) + w);
  }
  if (!raw.size) return new Map();

  // Normaliser 0-100 relativement au max de la fenêtre
  const maxRaw = Math.max(...Array.from(raw.values()), 1);
  const normalized = new Map<string, number>();
  for (const [id, score] of raw) normalized.set(id, clamp((score / maxRaw) * 100));
  return normalized;
}

// ✅ NOUVEAU : score fiabilité vendeur (depuis le cache)
async function getVendorReliabilityMap(vendorUserIds: string[]): Promise<Map<string, number>> {
  if (!vendorUserIds.length) return new Map();
  const { data, error } = await supabaseAdmin
    .from('vendor_reliability_cache')
    .select('vendor_user_id, reliability_score')
    .in('vendor_user_id', vendorUserIds);
  if (error) {
    logger.warn(`[Visibility] Reliability cache error (non-blocking): ${error.message}`);
    return new Map();
  }
  const result = new Map<string, number>();
  for (const row of data || []) {
    const uid = (row as any).vendor_user_id as string;
    if (uid) result.set(uid, Number((row as any).reliability_score ?? 100));
  }
  return result;
}

// ✅ NOUVEAU : bonus nouveau vendeur (linéaire décroissant sur N jours)
function computeNewVendorBonus(createdAt: Date | undefined, bonusDays: number, maxBonus: number): number {
  if (!createdAt) return 0;
  const ageDays = (Date.now() - createdAt.getTime()) / 86_400_000;
  if (ageDays >= bonusDays || bonusDays <= 0) return 0;
  return clamp(maxBonus * (1 - ageDays / bonusDays), 0, maxBonus);
}

async function getActiveBoostMap(
  candidates: VisibilityCandidate[],
  context?: Record<string, any>          // ✅ optionnel (compatible existant) — filtrage géo
): Promise<Map<string, number>> {
  if (!candidates.length) return new Map();

  const productIds = candidates.filter(c => c.itemType !== 'professional_service').map(c => c.id);
  const vendorIds = candidates.map(c => c.vendorId).filter((v): v is string => !!v);

  let query = supabaseAdmin
    .from('marketplace_visibility_boosts')
    .select('target_type, target_id, boost_score, target_country, target_city')
    .eq('status', 'active')
    .lte('starts_at', new Date().toISOString())
    .gte('ends_at', new Date().toISOString());

  if (productIds.length && vendorIds.length) {
    query = query.or(`and(target_type.eq.product,target_id.in.(${productIds.join(',')})),and(target_type.eq.shop,target_id.in.(${vendorIds.join(',')}))`);
  } else if (productIds.length) {
    query = query.eq('target_type', 'product').in('target_id', productIds);
  } else if (vendorIds.length) {
    query = query.eq('target_type', 'shop').in('target_id', vendorIds);
  } else {
    return new Map();
  }

  const { data, error } = await query;
  if (error) {
    logger.warn(`[Visibility] Failed to load boosts: ${error.message}`);
    return new Map();
  }

  // ✅ Filtrage géolocalisé : un boost ciblé (pays/ville) n'est appliqué que si
  // le contexte correspond. NULL = mondial (comportement original préservé).
  const ctxCountry = ((context?.country as string) || '').toLowerCase().trim();
  const ctxCity    = ((context?.city as string) || '').toLowerCase().trim();
  const relevantBoosts = (data || []).filter((row: any) => {
    const bCountry = ((row.target_country as string) || '').toLowerCase().trim();
    const bCity    = ((row.target_city as string) || '').toLowerCase().trim();
    if (bCountry && bCountry !== 'all' && ctxCountry && bCountry !== ctxCountry) return false;
    if (bCity    && bCity    !== 'all' && ctxCity    && bCity    !== ctxCity)    return false;
    return true;
  });

  const boostMap = new Map<string, number>();
  for (const row of relevantBoosts) {
    const type = String((row as any).target_type || '');
    const targetId = String((row as any).target_id || '');
    const score = Number((row as any).boost_score || 0);
    if (!targetId) continue;
    boostMap.set(`${type}:${targetId}`, (boostMap.get(`${type}:${targetId}`) || 0) + score);
  }

  return boostMap;
}

async function getProductMetrics(candidates: VisibilityCandidate[]): Promise<Map<string, Record<string, any>>> {
  const productIds = candidates.filter(c => c.itemType === 'product').map(c => c.id);
  const digitalIds = candidates.filter(c => c.itemType === 'digital_product').map(c => c.id);
  const serviceIds = candidates.filter(c => c.itemType === 'professional_service').map(c => c.id);

  const metricsMap = new Map<string, Record<string, any>>();

  if (productIds.length) {
    const { data } = await supabaseAdmin
      .from('products')
      .select('id, sales_count, rating, reviews_count, stock_quantity, is_active, description, images')
      .in('id', productIds);

    for (const row of data || []) {
      metricsMap.set(`product:${(row as any).id}`, row as any);
    }
  }

  if (digitalIds.length) {
    const { data } = await supabaseAdmin
      .from('digital_products')
      .select('id, sales_count, rating, reviews_count, status, description, images')
      .in('id', digitalIds);

    for (const row of data || []) {
      metricsMap.set(`digital_product:${(row as any).id}`, row as any);
    }
  }

  if (serviceIds.length) {
    const { data } = await supabaseAdmin
      .from('professional_services')
      .select('id, rating, total_reviews, status, description, logo_url, cover_image_url')
      .in('id', serviceIds);

    for (const row of data || []) {
      metricsMap.set(`professional_service:${(row as any).id}`, row as any);
    }
  }

  return metricsMap;
}

function qualityScore(candidate: VisibilityCandidate, metrics: Record<string, any> | undefined): number {
  const rating = Number(metrics?.rating ?? candidate.rating ?? 0);
  const reviews = Number(metrics?.reviews_count ?? metrics?.total_reviews ?? candidate.reviewsCount ?? 0);

  const descriptionLen = Number(metrics?.description?.length ?? candidate.descriptionLength ?? 0);
  const imageCount = Array.isArray(metrics?.images)
    ? metrics.images.length
    : Number(candidate.imageCount ?? (metrics?.logo_url ? 1 : 0) + (metrics?.cover_image_url ? 1 : 0));

  const ratingPart = clamp((rating / 5) * 45);
  const reviewsPart = clamp(Math.log10(reviews + 1) * 15);
  const descriptionPart = clamp((descriptionLen / 600) * 20);
  const mediaPart = clamp((imageCount / 5) * 20);

  return clamp(ratingPart + reviewsPart + descriptionPart + mediaPart);
}

function performanceScore(metrics: Record<string, any> | undefined): number {
  const sales = Number(metrics?.sales_count ?? 0);
  const reviews = Number(metrics?.reviews_count ?? metrics?.total_reviews ?? 0);
  const rating = Number(metrics?.rating ?? 0);

  const salesPart = clamp(Math.log10(sales + 1) * 40);
  const reviewPart = clamp(Math.log10(reviews + 1) * 25);
  const ratingPart = clamp((rating / 5) * 35);

  return clamp(salesPart + reviewPart + ratingPart);
}

function isItemEligible(candidate: VisibilityCandidate, metrics: Record<string, any> | undefined): boolean {
  if (!metrics) return true;

  if (candidate.itemType === 'product') {
    if (metrics.is_active === false) return false;
    const stock = Number(metrics.stock_quantity ?? 0);
    if (Number.isFinite(stock) && stock <= 0) return false;
  }

  if (candidate.itemType === 'digital_product') {
    if (String(metrics.status || '').toLowerCase() !== 'published') return false;
  }

  if (candidate.itemType === 'professional_service') {
    if (String(metrics.status || '').toLowerCase() !== 'active') return false;
  }

  return true;
}

function applyDiversityPenalty(scored: ScoredItem[], penalty: number): ScoredItem[] {
  const byVendorCount = new Map<string, number>();

  return scored
    .sort((a, b) => b.finalScore - a.finalScore)
    .map((item) => {
      const key = item.vendorUserId || `anon:${item.id}`;
      const seen = byVendorCount.get(key) || 0;
      byVendorCount.set(key, seen + 1);

      if (seen === 0) return item;
      const adjusted = {
        ...item,
        finalScore: clamp(item.finalScore - seen * penalty),
      };
      return adjusted;
    })
    .sort((a, b) => b.finalScore - a.finalScore);
}

export async function rankMarketplaceCandidates(candidates: VisibilityCandidate[], context?: Record<string, any>) {
  if (!Array.isArray(candidates) || !candidates.length) {
    return {
      success: true,
      orderedIds: [] as string[],
      scores: {} as Record<string, any>,
      meta: { total: 0 },
    };
  }

  const [config, planScoresMap, metricsMap, boostMap] = await Promise.all([
    getConfig(),
    getPlanScoresMap(),
    getProductMetrics(candidates),
    getActiveBoostMap(candidates, context), // ✅ context → filtrage géo des boosts
  ]);

  const vendorUserIds = Array.from(new Set(candidates.map(c => c.vendorUserId).filter((v): v is string => !!v)));

  // ✅ Chargements parallèles des nouvelles données
  const [vendorPlanMap, vendorCreationMap, trendScoreMap, vendorReliabilityMap] = await Promise.all([
    getVendorPlanMap(vendorUserIds),
    getVendorCreationMap(vendorUserIds),
    getTrendScoreMap(candidates, config.trend_window_hours),
    getVendorReliabilityMap(vendorUserIds),
  ]);

  const preferredCats: string[] = Array.isArray(context?.userPreferredCategories)
    ? (context!.userPreferredCategories as string[]) : [];

  const scored: ScoredItem[] = candidates
    .map((candidate) => {
      const metrics = metricsMap.get(`${candidate.itemType}:${candidate.id}`);

      if (!isItemEligible(candidate, metrics)) return null;

      const planName = String(vendorPlanMap[candidate.vendorUserId || ''] || 'free').toLowerCase();
      const basePlanScore = Number(planScoresMap[planName] ?? planScoresMap.free ?? 30);

      const perf = performanceScore(metrics);
      const quality = qualityScore(candidate, metrics);

      const productBoost = boostMap.get(`product:${candidate.id}`) || 0;
      const shopBoost = candidate.vendorId ? (boostMap.get(`shop:${candidate.vendorId}`) || 0) : 0;
      const boost = clamp(productBoost + shopBoost);

      const relevance = relevanceFromRecency(candidate.createdAt, config.rotation_factor);

      // ✅ Signal tendance (vues/paniers/achats récents) → 0..trend_weight
      const rawTrend = trendScoreMap.get(candidate.id) || 0;
      const trendBonus = clamp((rawTrend / 100) * config.trend_weight);

      // ✅ Bonus nouveau vendeur (dégressif sur N jours)
      const vendorCreatedAt = vendorCreationMap.get(candidate.vendorUserId || '');
      const newVendorBonus = computeNewVendorBonus(
        vendorCreatedAt, config.new_vendor_bonus_days, config.new_vendor_max_bonus
      );

      // ✅ Pénalité fiabilité vendeur (litiges + retours) : 0..-30
      const reliability = vendorReliabilityMap.get(candidate.vendorUserId || '') ?? 100;
      const reliabilityPenalty = clamp((100 - reliability) * 0.3);

      // ✅ Pénalité stock faible (stock_quantity déjà chargé dans getProductMetrics)
      const stockQty = Number(metrics?.stock_quantity ?? Infinity);
      const lowStockPenalty = (
        candidate.itemType === 'product' && stockQty > 0 && stockQty <= config.low_stock_threshold
      ) ? config.low_stock_penalty : 0;

      // ✅ Bonus catégorie préférée utilisateur (depuis le contexte)
      const itemCategory = String(metrics?.category_name || metrics?.category || '').toLowerCase().trim();
      const categoryBonus = (preferredCats.length > 0 && itemCategory &&
        preferredCats.some(c => c.toLowerCase().trim() === itemCategory)) ? 10 : 0;

      const weighted =
        (basePlanScore * config.subscription_weight) / 100 +
        (perf * config.performance_weight) / 100 +
        (boost * config.boost_weight) / 100 +
        (quality * config.quality_weight) / 100 +
        (relevance * config.relevance_weight) / 100;

      const qualityFloorPenalty = quality < config.min_quality_threshold ? 15 : 0;
      const sponsoredBonus = candidate.isSponsored ? 5 : 0;

      // ✅ Score final enrichi (additif — tous les existants préservés)
      const finalScore = clamp(
        weighted
        + sponsoredBonus           // existant : +5 si sponsorisé
        + trendBonus               // ✅ +0..+15 (signal chaud)
        + newVendorBonus           // ✅ +0..+30 (vendeur récent)
        + categoryBonus            // ✅ +10 si catégorie préférée
        - qualityFloorPenalty      // existant : -15 si fiche trop vide
        - reliabilityPenalty       // ✅ -0..-30 (litiges + retours)
        - lowStockPenalty          // ✅ -5 si stock ≤ seuil
      );

      return {
        id: candidate.id,
        itemType: candidate.itemType,
        vendorUserId: candidate.vendorUserId || null,
        subscriptionScore: basePlanScore,
        performanceScore: perf,
        boostScore: boost,
        qualityScore: quality,
        relevanceScore: relevance,
        finalScore,
        trendBonus: Math.round(trendBonus * 10) / 10,
        newVendorBonus: Math.round(newVendorBonus * 10) / 10,
        reliabilityPenalty: Math.round(reliabilityPenalty * 10) / 10,
        lowStockPenalty,
        categoryBonus,
        breakdown: {
          planName,
          productBoost,
          shopBoost,
          qualityFloorPenalty,
          sponsoredBonus,
          // ✅ nouveaux éléments de breakdown
          trendBonus: Math.round(trendBonus * 10) / 10,
          newVendorBonus: Math.round(newVendorBonus * 10) / 10,
          reliabilityPenalty: Math.round(reliabilityPenalty * 10) / 10,
          lowStockPenalty,
          categoryBonus,
          vendorAgeDays: vendorCreatedAt
            ? Math.floor((Date.now() - vendorCreatedAt.getTime()) / 86_400_000) : null,
          trendRawScore: Math.round(rawTrend * 10) / 10,
        },
      } as ScoredItem;
    })
    .filter((x): x is ScoredItem => !!x);

  const diversified = applyDiversityPenalty(scored, config.vendor_diversity_penalty);

  const orderedIds = diversified.map(s => s.id);
  const scores = Object.fromEntries(
    diversified.map(s => [
      s.id,
      {
        subscriptionScore: s.subscriptionScore,
        performanceScore: s.performanceScore,
        boostScore: s.boostScore,
        qualityScore: s.qualityScore,
        relevanceScore: s.relevanceScore,
        finalScore: s.finalScore,
        breakdown: s.breakdown,
      },
    ])
  );

  if (context?.persistLogs === true && diversified.length <= 300) {
    const logs = diversified.map(item => ({
      item_id: item.id,
      item_type: item.itemType,
      vendor_user_id: item.vendorUserId,
      subscription_score: item.subscriptionScore,
      performance_score: item.performanceScore,
      boost_score: item.boostScore,
      quality_score: item.qualityScore,
      relevance_score: item.relevanceScore,
      final_score: item.finalScore,
      context: context || {},
    }));

    const { error } = await supabaseAdmin.from('marketplace_visibility_score_logs').insert(logs);
    if (error) {
      logger.warn(`[Visibility] Failed to persist score logs: ${error.message}`);
    }
  }

  return {
    success: true,
    orderedIds,
    scores,
    meta: {
      total: diversified.length,
      config,
    },
  };
}

// ✅ NOUVEAU : checklist de visibilité pour le dashboard vendeur
function buildVendorChecklist(params: {
  planName: string;
  baseScore: number;
  activeBoostScore: number;
  topProduct?: Record<string, any>;
}): Array<{ done: boolean; action: string; impact: string; priority: number }> {
  const { planName, activeBoostScore, topProduct } = params;
  const tp = (topProduct || {}) as any;
  return [
    {
      priority: 1,
      done: (tp?.description?.length || 0) >= 600,
      action: 'Ajouter une description de 600+ caractères sur votre produit principal',
      impact: '+20 pts qualité',
    },
    {
      priority: 2,
      done: Array.isArray(tp?.images) && tp.images.length >= 5,
      action: 'Ajouter 5 photos ou plus',
      impact: '+20 pts qualité',
    },
    {
      priority: 3,
      done: (tp?.reviews_count || 0) >= 10,
      action: 'Obtenir 10 avis clients',
      impact: '+11 pts performance',
    },
    {
      priority: 4,
      done: !['free', 'basic'].includes(String(planName).toLowerCase()),
      action: 'Passer au plan Pro ou supérieur',
      impact: '+25 à +60 pts abonnement',
    },
    {
      priority: 5,
      done: activeBoostScore > 0,
      action: 'Activer un boost produit ou boutique',
      impact: "+jusqu'à 30 pts boost",
    },
  ];
}

export async function getVendorVisibilitySummary(vendorUserId: string) {
  const [planScoresMap, vendorPlanMap] = await Promise.all([
    getPlanScoresMap(),
    getVendorPlanMap([vendorUserId]),
  ]);

  const planName = vendorPlanMap[vendorUserId] || 'free';
  const baseScore = Number(planScoresMap[planName] ?? planScoresMap.free ?? 30);

  const nowIso = new Date().toISOString();
  const { data: boosts, error: boostError } = await supabaseAdmin
    .from('marketplace_visibility_boosts')
    .select('id, target_type, target_id, status, boost_score, starts_at, ends_at, budget_amount, amount_paid, payment_reference, created_at')
    .eq('owner_user_id', vendorUserId)
    .order('created_at', { ascending: false })
    .limit(50);

  if (boostError) {
    logger.warn(`[Visibility] vendor boosts error: ${boostError.message}`);
  }

  const activeBoostScore = (boosts || [])
    .filter((b: any) => b.status === 'active' && (!b.starts_at || b.starts_at <= nowIso) && (!b.ends_at || b.ends_at >= nowIso))
    .reduce((acc: number, b: any) => acc + Number(b.boost_score || 0), 0);

  const { data: topProducts } = await supabaseAdmin
    .from('products')
    .select('id, name, sales_count, rating, reviews_count, is_sponsored, description, images')
    .eq('vendor_id', (await supabaseAdmin.from('vendors').select('id').eq('user_id', vendorUserId).maybeSingle()).data?.id || '')
    .order('sales_count', { ascending: false })
    .limit(10);

  return {
    planName,
    baseVisibilityScore: baseScore,
    activeBoostScore,
    currentVisibilityScore: clamp(baseScore + activeBoostScore),
    boosts: boosts || [],
    topProducts: topProducts || [],
    // ✅ NOUVEAU : checklist d'actions pour améliorer la visibilité
    checklist: buildVendorChecklist({
      planName,
      baseScore,
      activeBoostScore,
      topProduct: ((topProducts || []) as any[])[0],
    }),
  };
}

export async function getVisibilityAdminOverview() {
  const nowIso = new Date().toISOString();

  const [settingsResult, planScoresResult, activeBoostsResult, totalBoostRevenueResult] = await Promise.all([
    supabaseAdmin
      .from('marketplace_visibility_settings')
      .select('*')
      .eq('is_active', true)
      .order('updated_at', { ascending: false })
      .limit(1)
      .maybeSingle(),
    supabaseAdmin
      .from('marketplace_visibility_plan_scores')
      .select('*')
      .order('base_score', { ascending: false }),
    supabaseAdmin
      .from('marketplace_visibility_boosts')
      .select('id, owner_user_id, target_type, target_id, boost_score, amount_paid, starts_at, ends_at, status')
      .eq('status', 'active')
      .lte('starts_at', nowIso)
      .gte('ends_at', nowIso),
    supabaseAdmin
      .from('marketplace_visibility_boosts')
      .select('amount_paid')
      .in('status', ['active', 'expired']),
  ]);

  const activeBoosts = activeBoostsResult.data || [];
  const totalBoostRevenue = (totalBoostRevenueResult.data || []).reduce((sum: number, row: any) => sum + Number(row.amount_paid || 0), 0);

  const topBoostVendorsMap = new Map<string, number>();
  for (const boost of activeBoosts) {
    const owner = String((boost as any).owner_user_id || '');
    if (!owner) continue;
    topBoostVendorsMap.set(owner, (topBoostVendorsMap.get(owner) || 0) + Number((boost as any).boost_score || 0));
  }

  const topBoostVendors = Array.from(topBoostVendorsMap.entries())
    .sort((a, b) => b[1] - a[1])
    .slice(0, 10)
    .map(([vendorUserId, totalBoostScore]) => ({ vendorUserId, totalBoostScore }));

  return {
    settings: settingsResult.data || DEFAULT_CONFIG,
    planScores: planScoresResult.data || [],
    activeBoostCount: activeBoosts.length,
    totalBoostRevenue,
    topBoostVendors,
    activeBoosts,
  };
}
