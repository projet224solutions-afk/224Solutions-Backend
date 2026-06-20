/**
 * 🚀 REAL-TIME ANALYTICS & SPIKE DETECTION SERVICE
 *
 * Production-ready real-time analytics with:
 * - Live view tracking via Redis streams
 * - Spike/trend detection using sliding windows
 * - Vendor notifications via Supabase Realtime
 * - PostgreSQL remains source of truth
 *
 * ARCHITECTURE:
 * ┌─────────────┐     ┌─────────────┐     ┌──────────────────┐
 * │   Tracking  │────▶│    Redis    │────▶│  Spike Detector  │
 * │   Events    │     │  (Stream)   │     │  (Sliding Window)│
 * └─────────────┘     └─────────────┘     └────────┬─────────┘
 *                                                   │
 *                     ┌─────────────┐               ▼
 *                     │  PostgreSQL │◀────┐  ┌─────────────┐
 *                     │  (Truth)    │     │  │  Notify     │
 *                     └─────────────┘     │  │  Service    │
 *                                         │  └─────────────┘
 *                     ┌─────────────┐     │
 *                     │  Supabase   │◀────┘
 *                     │  Realtime   │
 *                     └─────────────┘
 */

import Redis from 'ioredis';
import { logger } from '../config/logger.js';
import { supabaseAdmin } from '../config/supabase.js';

// ============================================================================
// CONFIGURATION
// ============================================================================

const REDIS_CONFIG = {
  host: process.env.REDIS_HOST || 'localhost',
  port: parseInt(process.env.REDIS_PORT) || 6379,
  password: process.env.REDIS_PASSWORD || undefined,
  db: parseInt(process.env.REDIS_DB) || 0,
  maxRetriesPerRequest: 3,
  lazyConnect: true,
};

// Redis key schema for real-time analytics
const KEYS = {
  // Sliding window counters (per minute)
  VIEWS_MINUTE: 'rt:views:m:',           // rt:views:m:{vendorId}:{minute}
  VISITS_MINUTE: 'rt:visits:m:',         // rt:visits:m:{vendorId}:{minute}

  // Hourly aggregates for comparison
  VIEWS_HOUR: 'rt:views:h:',             // rt:views:h:{vendorId}:{hour}
  VISITS_HOUR: 'rt:visits:h:',           // rt:visits:h:{vendorId}:{hour}

  // Product-level tracking
  PRODUCT_VIEWS_MINUTE: 'rt:pv:m:',      // rt:pv:m:{productId}:{minute}

  // Baseline averages (rolling 7-day)
  BASELINE_VIEWS: 'rt:base:views:',      // rt:base:views:{vendorId}:{hourOfDay}
  BASELINE_VISITS: 'rt:base:visits:',    // rt:base:visits:{vendorId}:{hourOfDay}

  // Spike detection state
  SPIKE_STATE: 'rt:spike:',              // rt:spike:{vendorId}:{type}
  LAST_NOTIFICATION: 'rt:notif:',        // rt:notif:{vendorId}:{type}

  // Live subscriptions (which vendors are online)
  LIVE_VENDORS: 'rt:live:vendors',       // Set of online vendor IDs

  // Event stream for real-time updates
  EVENT_STREAM: 'rt:stream:events',      // Redis stream for all events
};

// TTL values in seconds
const TTL = {
  MINUTE_COUNTER: 120,      // 2 minutes (buffer for late events)
  HOUR_COUNTER: 7200,       // 2 hours
  BASELINE: 604800,         // 7 days
  SPIKE_STATE: 3600,        // 1 hour (cooldown)
  NOTIFICATION_COOLDOWN: 900, // 15 minutes between same notifications
};

// Spike detection thresholds
const THRESHOLDS = {
  // Minimum events before spike detection kicks in
  MIN_EVENTS_FOR_DETECTION: 10,

  // Spike: current > baseline * multiplier
  SPIKE_MULTIPLIER: 2.5,     // 150% above baseline = spike
  TREND_MULTIPLIER: 1.5,     // 50% above baseline = trend up

  // Absolute minimums to avoid false positives
  MIN_SPIKE_VIEWS: 20,       // At least 20 views/hour for spike
  MIN_SPIKE_VISITS: 10,      // At least 10 visits/hour for spike

  // Trending product thresholds
  PRODUCT_TRENDING_VIEWS: 50, // 50+ views in last hour
  PRODUCT_HOT_MULTIPLIER: 3,  // 3x normal = "hot" product
};

// ============================================================================
// REDIS CLIENT
// ============================================================================

let redisClient = null;
let isConnected = false;

async function getRedis() {
  if (redisClient && isConnected) {
    return redisClient;
  }

  try {
    if (!redisClient) {
      redisClient = new Redis(REDIS_CONFIG);

      redisClient.on('connect', () => {
        isConnected = true;
        logger.info('✅ Real-time analytics Redis connected');
      });

      redisClient.on('error', (err) => {
        isConnected = false;
        logger.error(`Real-time Redis error: ${err.message}`);
      });
    }

    if (!isConnected) {
      await redisClient.connect();
    }

    return redisClient;
  } catch (error) {
    logger.error(`Real-time Redis connection failed: ${error.message}`);
    return null;
  }
}

// ============================================================================
// TIME UTILITIES
// ============================================================================

/**
 * Get current minute key (YYYYMMDDHHMM)
 */
function getMinuteKey() {
  const now = new Date();
  return now.toISOString().slice(0, 16).replace(/[-:T]/g, '');
}

/**
 * Get current hour key (YYYYMMDDHH)
 */
function getHourKey() {
  const now = new Date();
  return now.toISOString().slice(0, 13).replace(/[-:T]/g, '');
}

/**
 * Get hour of day (0-23) for baseline comparison
 */
function getHourOfDay() {
  return new Date().getUTCHours();
}

/**
 * Get minute keys for last N minutes
 */
function getLastNMinuteKeys(n) {
  const keys = [];
  const now = Date.now();

  for (let i = 0; i < n; i++) {
    const time = new Date(now - i * 60000);
    keys.push(time.toISOString().slice(0, 16).replace(/[-:T]/g, ''));
  }

  return keys;
}

// ============================================================================
// REAL-TIME EVENT TRACKING
// ============================================================================

/**
 * Track a real-time event (product view or shop visit)
 * This is called in addition to the persistent tracking
 *
 * @param {Object} event
 * @param {string} event.type - 'product_view' | 'shop_visit'
 * @param {string} event.vendorId
 * @param {string} event.productId - Optional, for product views
 * @param {string} event.visitorId - User ID or session ID
 * @param {Object} event.metadata - Additional data
 */
export async function trackRealtimeEvent(event) {
  const redis = await getRedis();
  if (!redis) {
    logger.debug('Redis unavailable, skipping real-time tracking');
    return null;
  }

  const { type, vendorId, productId, visitorId, metadata = {} } = event;
  const minuteKey = getMinuteKey();
  const hourKey = getHourKey();

  try {
    const pipeline = redis.pipeline();

    if (type === 'product_view') {
      // Increment vendor-level view counters
      const viewMinuteKey = `${KEYS.VIEWS_MINUTE}${vendorId}:${minuteKey}`;
      const viewHourKey = `${KEYS.VIEWS_HOUR}${vendorId}:${hourKey}`;

      pipeline.incr(viewMinuteKey);
      pipeline.expire(viewMinuteKey, TTL.MINUTE_COUNTER);
      pipeline.incr(viewHourKey);
      pipeline.expire(viewHourKey, TTL.HOUR_COUNTER);

      // Increment product-level counters
      if (productId) {
        const productMinuteKey = `${KEYS.PRODUCT_VIEWS_MINUTE}${productId}:${minuteKey}`;
        pipeline.incr(productMinuteKey);
        pipeline.expire(productMinuteKey, TTL.MINUTE_COUNTER);
      }

    } else if (type === 'shop_visit') {
      // Increment visit counters
      const visitMinuteKey = `${KEYS.VISITS_MINUTE}${vendorId}:${minuteKey}`;
      const visitHourKey = `${KEYS.VISITS_HOUR}${vendorId}:${hourKey}`;

      pipeline.incr(visitMinuteKey);
      pipeline.expire(visitMinuteKey, TTL.MINUTE_COUNTER);
      pipeline.incr(visitHourKey);
      pipeline.expire(visitHourKey, TTL.HOUR_COUNTER);
    }

    // Add to event stream for real-time subscribers
    pipeline.xadd(
      KEYS.EVENT_STREAM,
      'MAXLEN', '~', '10000',  // Keep last ~10k events
      '*',  // Auto-generate ID
      'type', type,
      'vendorId', vendorId,
      'productId', productId || '',
      'timestamp', Date.now().toString()
    );

    await pipeline.exec();

    // Check for spikes asynchronously (don't block the tracking)
    setImmediate(() => checkForSpikes(vendorId, type));

    return { success: true, minuteKey };

  } catch (error) {
    logger.error(`Real-time tracking error: ${error.message}`);
    return null;
  }
}

// ============================================================================
// REAL-TIME COUNTER RETRIEVAL
// ============================================================================

/**
 * Get real-time stats for a vendor (for live dashboard)
 *
 * @param {string} vendorId
 * @returns {Object} Real-time statistics
 */
export async function getRealtimeStats(vendorId) {
  const redis = await getRedis();

  if (!redis) {
    // Fallback to PostgreSQL for basic stats
    return getStatsFallback(vendorId);
  }

  try {
    const hourKey = getHourKey();
    const minuteKeys = getLastNMinuteKeys(5); // Last 5 minutes

    const pipeline = redis.pipeline();

    // Get hour totals
    pipeline.get(`${KEYS.VIEWS_HOUR}${vendorId}:${hourKey}`);
    pipeline.get(`${KEYS.VISITS_HOUR}${vendorId}:${hourKey}`);

    // Get last 5 minutes for "velocity" calculation
    minuteKeys.forEach(mk => {
      pipeline.get(`${KEYS.VIEWS_MINUTE}${vendorId}:${mk}`);
      pipeline.get(`${KEYS.VISITS_MINUTE}${vendorId}:${mk}`);
    });

    // Get baseline for comparison
    const hourOfDay = getHourOfDay();
    pipeline.get(`${KEYS.BASELINE_VIEWS}${vendorId}:${hourOfDay}`);
    pipeline.get(`${KEYS.BASELINE_VISITS}${vendorId}:${hourOfDay}`);

    const results = await pipeline.exec();

    const viewsThisHour = parseInt(results[0][1]) || 0;
    const visitsThisHour = parseInt(results[1][1]) || 0;

    // Calculate 5-minute velocity
    let recentViews = 0;
    let recentVisits = 0;
    for (let i = 0; i < 5; i++) {
      recentViews += parseInt(results[2 + i * 2][1]) || 0;
      recentVisits += parseInt(results[3 + i * 2][1]) || 0;
    }

    const baselineViews = parseFloat(results[12][1]) || 0;
    const baselineVisits = parseFloat(results[13][1]) || 0;

    // Calculate trend percentage
    const viewsTrend = baselineViews > 0
      ? ((viewsThisHour - baselineViews) / baselineViews * 100).toFixed(1)
      : 0;
    const visitsTrend = baselineVisits > 0
      ? ((visitsThisHour - baselineVisits) / baselineVisits * 100).toFixed(1)
      : 0;

    return {
      source: 'redis',
      timestamp: new Date().toISOString(),
      productViews: {
        thisHour: viewsThisHour,
        last5Minutes: recentViews,
        velocity: Math.round(recentViews / 5 * 60), // Views per hour rate
        baseline: Math.round(baselineViews),
        trend: parseFloat(viewsTrend),
        status: getStatusFromTrend(viewsTrend)
      },
      shopVisits: {
        thisHour: visitsThisHour,
        last5Minutes: recentVisits,
        velocity: Math.round(recentVisits / 5 * 60),
        baseline: Math.round(baselineVisits),
        trend: parseFloat(visitsTrend),
        status: getStatusFromTrend(visitsTrend)
      }
    };

  } catch (error) {
    logger.error(`Get realtime stats error: ${error.message}`);
    return getStatsFallback(vendorId);
  }
}

/**
 * Get trending products for a vendor
 */
export async function getTrendingProducts(vendorId, limit = 5) {
  const redis = await getRedis();
  if (!redis) return [];

  try {
    // Get all product view keys for this vendor from last hour
    const pattern = `${KEYS.PRODUCT_VIEWS_MINUTE}*`;
    const keys = await redis.keys(pattern);

    if (keys.length === 0) return [];

    // Get counts and aggregate by product
    const productCounts = {};
    const pipeline = redis.pipeline();

    keys.forEach(key => pipeline.get(key));
    const results = await pipeline.exec();

    keys.forEach((key, i) => {
      // Extract productId from key: rt:pv:m:{productId}:{minute}
      const parts = key.split(':');
      const productId = parts[3];
      const count = parseInt(results[i][1]) || 0;

      productCounts[productId] = (productCounts[productId] || 0) + count;
    });

    // Sort by count and get top products
    const sorted = Object.entries(productCounts)
      .sort((a, b) => b[1] - a[1])
      .slice(0, limit);

    // Enrich with product names from PostgreSQL
    if (sorted.length > 0) {
      const productIds = sorted.map(([id]) => id);

      const { data: products } = await supabaseAdmin
        .from('products')
        .select('id, name, images')
        .in('id', productIds);

      const productMap = new Map(products?.map(p => [p.id, p]) || []);

      return sorted.map(([productId, views]) => ({
        productId,
        name: productMap.get(productId)?.name || 'Unknown',
        imageUrl: productMap.get(productId)?.images?.[0] || null,
        viewsLastHour: views,
        isTrending: views >= THRESHOLDS.PRODUCT_TRENDING_VIEWS
      }));
    }

    return [];

  } catch (error) {
    logger.error(`Get trending products error: ${error.message}`);
    return [];
  }
}

// ============================================================================
// SPIKE & TREND DETECTION
// ============================================================================

/**
 * Check for traffic spikes and trigger notifications
 */
async function checkForSpikes(vendorId, eventType) {
  const redis = await getRedis();
  if (!redis) return;

  try {
    const hourKey = getHourKey();
    const hourOfDay = getHourOfDay();

    // Get current hour stats
    const isViews = eventType === 'product_view';
    const counterKey = isViews
      ? `${KEYS.VIEWS_HOUR}${vendorId}:${hourKey}`
      : `${KEYS.VISITS_HOUR}${vendorId}:${hourKey}`;
    const baselineKey = isViews
      ? `${KEYS.BASELINE_VIEWS}${vendorId}:${hourOfDay}`
      : `${KEYS.BASELINE_VISITS}${vendorId}:${hourOfDay}`;

    const [current, baseline] = await Promise.all([
      redis.get(counterKey),
      redis.get(baselineKey)
    ]);

    const currentCount = parseInt(current) || 0;
    const baselineCount = parseFloat(baseline) || 0;

    // Skip if not enough data
    if (currentCount < THRESHOLDS.MIN_EVENTS_FOR_DETECTION) {
      return;
    }

    // Check absolute minimums
    const minForSpike = isViews ? THRESHOLDS.MIN_SPIKE_VIEWS : THRESHOLDS.MIN_SPIKE_VISITS;
    if (currentCount < minForSpike) {
      return;
    }

    // Calculate ratio
    const ratio = baselineCount > 0 ? currentCount / baselineCount : currentCount;

    // Determine spike level
    let spikeLevel = null;
    if (ratio >= THRESHOLDS.SPIKE_MULTIPLIER) {
      spikeLevel = 'spike';
    } else if (ratio >= THRESHOLDS.TREND_MULTIPLIER) {
      spikeLevel = 'trending';
    }

    if (!spikeLevel) return;

    // Check cooldown (avoid spam)
    const notifKey = `${KEYS.LAST_NOTIFICATION}${vendorId}:${eventType}:${spikeLevel}`;
    const lastNotif = await redis.get(notifKey);

    if (lastNotif) {
      return; // Still in cooldown
    }

    // Record notification sent and trigger it
    await redis.setex(notifKey, TTL.NOTIFICATION_COOLDOWN, Date.now().toString());

    // Trigger notification
    await triggerSpikeNotification({
      vendorId,
      type: isViews ? 'product_views' : 'shop_visits',
      level: spikeLevel,
      current: currentCount,
      baseline: Math.round(baselineCount),
      ratio: ratio.toFixed(1)
    });

  } catch (error) {
    logger.error(`Spike check error: ${error.message}`);
  }
}

/**
 * Trigger vendor notification for spike/trend
 */
async function triggerSpikeNotification(data) {
  const { vendorId, type, level, current, baseline, ratio } = data;

  try {
    // Get vendor info
    const { data: vendor } = await supabaseAdmin
      .from('vendors')
      .select('user_id, name')
      .eq('id', vendorId)
      .single();

    if (!vendor) return;

    const isSpike = level === 'spike';
    const typeLabel = type === 'product_views' ? 'vues produits' : 'visites boutique';

    const title = isSpike
      ? `🔥 Pic de trafic détecté !`
      : `📈 Tendance positive`;

    const message = isSpike
      ? `Vos ${typeLabel} sont ${ratio}x au-dessus de la normale ! (${current} vs ${baseline} habituellement)`
      : `Vos ${typeLabel} sont en hausse: ${current} cette heure (habituellement ${baseline})`;

    // 1. Insert notification in database
    await supabaseAdmin
      .from('notifications')
      .insert({
        user_id: vendor.user_id,
        type: 'analytics',
        title,
        message,
        data: {
          vendorId,
          analyticsType: type,
          level,
          current,
          baseline,
          ratio
        }
      });

    // 2. Broadcast via Supabase Realtime (if vendor is subscribed)
    await supabaseAdmin
      .from('realtime_analytics_events')
      .insert({
        vendor_id: vendorId,
        event_type: level,
        payload: {
          type,
          current,
          baseline,
          ratio,
          message
        }
      });

    logger.info(`📢 Spike notification sent: vendor=${vendorId}, type=${type}, level=${level}`);

  } catch (error) {
    logger.error(`Spike notification error: ${error.message}`);
  }
}

// ============================================================================
// BASELINE MANAGEMENT
// ============================================================================

/**
 * Update baseline averages (called by cron job, e.g., hourly)
 * Uses exponential moving average for smooth updates
 */
export async function updateBaselines() {
  const redis = await getRedis();
  if (!redis) return;

  try {
    const hourOfDay = getHourOfDay();
    const previousHourKey = getHourKey(); // Current hour data

    // Get all vendors with activity in last hour
    const viewKeys = await redis.keys(`${KEYS.VIEWS_HOUR}*:${previousHourKey}`);
    const visitKeys = await redis.keys(`${KEYS.VISITS_HOUR}*:${previousHourKey}`);

    // Process views baselines
    for (const key of viewKeys) {
      const vendorId = key.split(':')[3];
      const count = parseInt(await redis.get(key)) || 0;

      await updateSingleBaseline(
        redis,
        `${KEYS.BASELINE_VIEWS}${vendorId}:${hourOfDay}`,
        count
      );
    }

    // Process visits baselines
    for (const key of visitKeys) {
      const vendorId = key.split(':')[3];
      const count = parseInt(await redis.get(key)) || 0;

      await updateSingleBaseline(
        redis,
        `${KEYS.BASELINE_VISITS}${vendorId}:${hourOfDay}`,
        count
      );
    }

    logger.info(`✅ Baselines updated for hour ${hourOfDay}`);

  } catch (error) {
    logger.error(`Update baselines error: ${error.message}`);
  }
}

/**
 * Update a single baseline using exponential moving average
 * EMA = α * current + (1 - α) * previous
 * α = 0.2 gives more weight to historical data (smoother)
 */
async function updateSingleBaseline(redis, key, newValue) {
  const ALPHA = 0.2; // Smoothing factor

  const existing = await redis.get(key);
  let newBaseline;

  if (existing) {
    const oldBaseline = parseFloat(existing);
    newBaseline = ALPHA * newValue + (1 - ALPHA) * oldBaseline;
  } else {
    newBaseline = newValue;
  }

  await redis.setex(key, TTL.BASELINE, newBaseline.toFixed(2));
}

// ============================================================================
// VENDOR SUBSCRIPTION MANAGEMENT
// ============================================================================

/**
 * Mark vendor as "live" (viewing their dashboard)
 */
export async function markVendorOnline(vendorId) {
  const redis = await getRedis();
  if (!redis) return;

  await redis.sadd(KEYS.LIVE_VENDORS, vendorId);
  // Auto-expire after 5 minutes of inactivity
  await redis.expire(KEYS.LIVE_VENDORS, 300);
}

/**
 * Check if vendor is online (for targeted notifications)
 */
export async function isVendorOnline(vendorId) {
  const redis = await getRedis();
  if (!redis) return false;

  return await redis.sismember(KEYS.LIVE_VENDORS, vendorId);
}

// ============================================================================
// FALLBACK & UTILITIES
// ============================================================================

/**
 * PostgreSQL fallback when Redis is unavailable
 */
async function getStatsFallback(vendorId) {
  try {
    const today = new Date().toISOString().split('T')[0];

    const { data } = await supabaseAdmin
      .from('analytics_daily_stats')
      .select('total_product_views, total_shop_visits')
      .eq('vendor_id', vendorId)
      .eq('stat_date', today)
      .single();

    return {
      source: 'postgres_fallback',
      timestamp: new Date().toISOString(),
      productViews: {
        today: data?.total_product_views || 0,
        thisHour: null,
        trend: null,
        status: 'unknown'
      },
      shopVisits: {
        today: data?.total_shop_visits || 0,
        thisHour: null,
        trend: null,
        status: 'unknown'
      }
    };
  } catch (error) {
    return {
      source: 'error',
      error: error.message
    };
  }
}

/**
 * Convert trend percentage to status label
 */
function getStatusFromTrend(trend) {
  const t = parseFloat(trend);
  if (t >= 100) return 'spike';
  if (t >= 50) return 'hot';
  if (t >= 20) return 'up';
  if (t > -20) return 'stable';
  if (t > -50) return 'down';
  return 'cold';
}

// ============================================================================
// HEALTH CHECK & CLEANUP
// ============================================================================

/**
 * Health check for real-time system
 */
export async function healthCheck() {
  const redis = await getRedis();

  if (!redis) {
    return {
      status: 'degraded',
      redis: false,
      message: 'Running in PostgreSQL fallback mode'
    };
  }

  try {
    const start = Date.now();
    await redis.ping();

    return {
      status: 'healthy',
      redis: true,
      latencyMs: Date.now() - start
    };
  } catch (error) {
    return {
      status: 'unhealthy',
      redis: false,
      error: error.message
    };
  }
}

/**
 * Export key schema for documentation
 */
export const REDIS_SCHEMA = KEYS;
export const DETECTION_THRESHOLDS = THRESHOLDS;

export default {
  trackRealtimeEvent,
  getRealtimeStats,
  getTrendingProducts,
  updateBaselines,
  markVendorOnline,
  isVendorOnline,
  healthCheck,
  REDIS_SCHEMA,
  DETECTION_THRESHOLDS
};
