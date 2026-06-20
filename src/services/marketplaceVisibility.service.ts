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

  const recencyScore = clamp(100 - ageDays * 1.2);
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
    .select('subscription_weight, performance_weight, boost_weight, quality_weight, relevance_weight, vendor_diversity_penalty, min_quality_threshold, rotation_factor')
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

async function getActiveBoostMap(candidates: VisibilityCandidate[]): Promise<Map<string, number>> {
  if (!candidates.length) return new Map();

  const productIds = candidates.filter(c => c.itemType !== 'professional_service').map(c => c.id);
  const vendorIds = candidates.map(c => c.vendorId).filter((v): v is string => !!v);

  let query = supabaseAdmin
    .from('marketplace_visibility_boosts')
    .select('target_type, target_id, boost_score')
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

  const boostMap = new Map<string, number>();
  for (const row of data || []) {
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
    getActiveBoostMap(candidates),
  ]);

  const vendorUserIds = Array.from(new Set(candidates.map(c => c.vendorUserId).filter((v): v is string => !!v)));
  const vendorPlanMap = await getVendorPlanMap(vendorUserIds);

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

      const weighted =
        (basePlanScore * config.subscription_weight) / 100 +
        (perf * config.performance_weight) / 100 +
        (boost * config.boost_weight) / 100 +
        (quality * config.quality_weight) / 100 +
        (relevance * config.relevance_weight) / 100;

      const qualityFloorPenalty = quality < config.min_quality_threshold ? 15 : 0;
      const sponsoredBonus = candidate.isSponsored ? 5 : 0;
      const finalScore = clamp(weighted + sponsoredBonus - qualityFloorPenalty);

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
        breakdown: {
          planName,
          productBoost,
          shopBoost,
          qualityFloorPenalty,
          sponsoredBonus,
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
    .select('id, name, sales_count, rating, reviews_count, is_sponsored')
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
