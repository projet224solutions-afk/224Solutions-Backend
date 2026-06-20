/**
 * 🚀 REDIS SERVICE FOR HIGH-PERFORMANCE ANALYTICS
 *
 * Production-ready Redis integration with:
 * - 24h deduplication using SETEX
 * - Real-time counters using HyperLogLog + sorted sets
 * - Automatic PostgreSQL fallback
 * - Connection pooling and retry logic
 *
 * PERFORMANCE TARGETS:
 * - Sub-millisecond dedup checks
 * - Support 10k → 1M daily views
 * - 99.9% uptime with fallback
 */

import Redis from 'ioredis';
import { logger } from '../config/logger.js';

// ============================================================================
// CONFIGURATION
// ============================================================================

// URL d'un Redis managé (prioritaire sur host/port). Même variable que config/redis.ts.
const REDIS_URL = process.env.REDIS_URL || process.env.UPSTASH_REDIS_URL || '';
// Activé si explicitement, OU URL fournie, OU production.
const REDIS_ENABLED =
  (process.env.REDIS_ENABLED ?? ((REDIS_URL || process.env.NODE_ENV === 'production') ? 'true' : 'false')) === 'true';

const REDIS_CONFIG = {
  host: process.env.REDIS_HOST || 'localhost',
  port: parseInt(process.env.REDIS_PORT) || 6379,
  password: process.env.REDIS_PASSWORD || undefined,
  db: parseInt(process.env.REDIS_DB) || 0,

  // Connection pool settings for high throughput
  maxRetriesPerRequest: 3,
  retryStrategy: (times) => {
    if (times > 10) {
      logger.error('Redis connection failed after 10 retries');
      return null; // Stop retrying, use fallback
    }
    return Math.min(times * 100, 3000); // Exponential backoff, max 3s
  },

  // Performance optimizations
  enableOfflineQueue: true,
  connectTimeout: 5000,
  commandTimeout: 1000,
  keepAlive: 30000,

  // Cluster support (optional)
  enableReadyCheck: true,
  lazyConnect: true,
};

// Key prefixes for organization
const KEYS = {
  // Deduplication keys (expire after 24h)
  PRODUCT_VIEW_DEDUP: 'dedup:pv:',        // dedup:pv:{productId}:{visitorHash}
  SHOP_VISIT_DEDUP: 'dedup:sv:',          // dedup:sv:{vendorId}:{visitorHash}

  // Real-time counters (HyperLogLog for unique visitors)
  PRODUCT_VIEWS_HLL: 'hll:pv:',           // hll:pv:{productId}:{date}
  SHOP_VISITS_HLL: 'hll:sv:',             // hll:sv:{vendorId}:{date}

  // Total counters (for exact counts)
  PRODUCT_VIEWS_COUNT: 'cnt:pv:',         // cnt:pv:{productId}:{date}
  SHOP_VISITS_COUNT: 'cnt:sv:',           // cnt:sv:{vendorId}:{date}

  // Batching queue
  BATCH_QUEUE: 'queue:analytics:batch',   // List for pending writes

  // Rate limiting
  RATE_LIMIT: 'rl:',                      // rl:{identifier}
};

// TTLs in seconds
const TTL = {
  DEDUPLICATION: 86400,      // 24 hours
  DAILY_COUNTER: 172800,     // 48 hours (buffer for timezone edge cases)
  RATE_LIMIT: 60,            // 1 minute
  BATCH_LOCK: 30,            // 30 seconds
};

// ============================================================================
// REDIS CLIENT MANAGEMENT
// ============================================================================

let redisClient = null;
let isRedisConnected = false;
let connectionAttempts = 0;
const MAX_CONNECTION_ATTEMPTS = 5;

/**
 * Initialize Redis connection with lazy loading
 * @returns {Promise<Redis|null>}
 */
async function getRedisClient() {
  if (!REDIS_ENABLED) {
    return null; // Désactivé (dev sans Redis) → fallback PostgreSQL
  }

  if (redisClient && isRedisConnected) {
    return redisClient;
  }

  if (connectionAttempts >= MAX_CONNECTION_ATTEMPTS) {
    return null; // Use fallback
  }

  try {
    connectionAttempts++;

    if (!redisClient) {
      redisClient = REDIS_URL ? new Redis(REDIS_URL, { lazyConnect: true }) : new Redis(REDIS_CONFIG);

      redisClient.on('connect', () => {
        isRedisConnected = true;
        connectionAttempts = 0;
        logger.info('✅ Redis connected successfully');
      });

      redisClient.on('error', (err) => {
        isRedisConnected = false;
        logger.error(`Redis error: ${err.message}`);
      });

      redisClient.on('close', () => {
        isRedisConnected = false;
        logger.warn('Redis connection closed');
      });
    }

    await redisClient.connect();
    return redisClient;

  } catch (error) {
    logger.error(`Redis connection failed: ${error.message}`);
    return null;
  }
}

/**
 * Check if Redis is available
 * @returns {boolean}
 */
export function isRedisAvailable() {
  return isRedisConnected && redisClient !== null;
}

// ============================================================================
// DEDUPLICATION FUNCTIONS
// ============================================================================

/**
 * Generate a unique key for deduplication
 * Uses fingerprint hash + user/session for uniqueness
 *
 * @param {string} type - 'product' or 'shop'
 * @param {string} targetId - Product ID or Vendor ID
 * @param {string} visitorHash - Fingerprint hash of visitor
 * @returns {string}
 */
function getDedupKey(type, targetId, visitorHash) {
  const prefix = type === 'product' ? KEYS.PRODUCT_VIEW_DEDUP : KEYS.SHOP_VISIT_DEDUP;
  return `${prefix}${targetId}:${visitorHash}`;
}

/**
 * Check if a view/visit is already tracked (24h window)
 * Uses SETNX for atomic check-and-set
 *
 * @param {string} type - 'product' or 'shop'
 * @param {string} targetId - Product ID or Vendor ID
 * @param {string} visitorHash - Fingerprint hash
 * @returns {Promise<{isDuplicate: boolean, source: 'redis'|'fallback'}>}
 */
export async function checkDeduplication(type, targetId, visitorHash) {
  const redis = await getRedisClient();
  const key = getDedupKey(type, targetId, visitorHash);

  if (redis) {
    try {
      // SETNX returns 1 if key was set (new view), 0 if already exists (duplicate)
      const result = await redis.set(key, '1', 'EX', TTL.DEDUPLICATION, 'NX');

      return {
        isDuplicate: result === null, // null means key already existed
        source: 'redis'
      };
    } catch (error) {
      logger.error(`Redis dedup check failed: ${error.message}`);
      // Fall through to fallback
    }
  }

  // Fallback: Return false to allow tracking, DB will handle dedup
  return {
    isDuplicate: false,
    source: 'fallback'
  };
}

/**
 * Mark a view as tracked in Redis (for batch processing)
 * @param {string} type
 * @param {string} targetId
 * @param {string} visitorHash
 */
export async function markAsTracked(type, targetId, visitorHash) {
  const redis = await getRedisClient();
  if (!redis) return false;

  try {
    const key = getDedupKey(type, targetId, visitorHash);
    await redis.setex(key, TTL.DEDUPLICATION, '1');
    return true;
  } catch (error) {
    logger.error(`Redis mark tracked failed: ${error.message}`);
    return false;
  }
}

// ============================================================================
// REAL-TIME COUNTERS
// ============================================================================

/**
 * Get the current date key for counters (YYYY-MM-DD)
 * @returns {string}
 */
function getDateKey() {
  return new Date().toISOString().split('T')[0];
}

/**
 * Increment counter and add to HyperLogLog for unique counts
 * Uses pipeline for atomicity and performance
 *
 * @param {string} type - 'product' or 'shop'
 * @param {string} targetId - Product ID or Vendor ID
 * @param {string} visitorHash - For unique counting
 * @returns {Promise<{total: number, unique: number}|null>}
 */
export async function incrementCounter(type, targetId, visitorHash) {
  const redis = await getRedisClient();
  if (!redis) return null;

  const dateKey = getDateKey();
  const countKey = (type === 'product' ? KEYS.PRODUCT_VIEWS_COUNT : KEYS.SHOP_VISITS_COUNT) + `${targetId}:${dateKey}`;
  const hllKey = (type === 'product' ? KEYS.PRODUCT_VIEWS_HLL : KEYS.SHOP_VISITS_HLL) + `${targetId}:${dateKey}`;

  try {
    const pipeline = redis.pipeline();

    // Increment total count
    pipeline.incr(countKey);
    pipeline.expire(countKey, TTL.DAILY_COUNTER);

    // Add to HyperLogLog for unique count
    pipeline.pfadd(hllKey, visitorHash);
    pipeline.expire(hllKey, TTL.DAILY_COUNTER);

    // Get current counts
    pipeline.get(countKey);
    pipeline.pfcount(hllKey);

    const results = await pipeline.exec();

    return {
      total: parseInt(results[4][1]) || 0,
      unique: parseInt(results[5][1]) || 0
    };
  } catch (error) {
    logger.error(`Redis counter increment failed: ${error.message}`);
    return null;
  }
}

/**
 * Get real-time counter values (for dashboard widgets)
 * @param {string} type
 * @param {string} targetId
 * @param {string} date - Optional date (defaults to today)
 * @returns {Promise<{total: number, unique: number}|null>}
 */
export async function getCounter(type, targetId, date = null) {
  const redis = await getRedisClient();
  if (!redis) return null;

  const dateKey = date || getDateKey();
  const countKey = (type === 'product' ? KEYS.PRODUCT_VIEWS_COUNT : KEYS.SHOP_VISITS_COUNT) + `${targetId}:${dateKey}`;
  const hllKey = (type === 'product' ? KEYS.PRODUCT_VIEWS_HLL : KEYS.SHOP_VISITS_HLL) + `${targetId}:${dateKey}`;

  try {
    const [total, unique] = await Promise.all([
      redis.get(countKey),
      redis.pfcount(hllKey)
    ]);

    return {
      total: parseInt(total) || 0,
      unique: unique || 0
    };
  } catch (error) {
    logger.error(`Redis counter get failed: ${error.message}`);
    return null;
  }
}

/**
 * Get counters for multiple days (for charts)
 * @param {string} type
 * @param {string} targetId
 * @param {number} days - Number of days to fetch
 * @returns {Promise<Array<{date: string, total: number, unique: number}>>}
 */
export async function getCounterHistory(type, targetId, days = 7) {
  const redis = await getRedisClient();
  if (!redis) return null;

  const results = [];
  const pipeline = redis.pipeline();

  for (let i = 0; i < days; i++) {
    const date = new Date();
    date.setDate(date.getDate() - i);
    const dateKey = date.toISOString().split('T')[0];

    const countKey = (type === 'product' ? KEYS.PRODUCT_VIEWS_COUNT : KEYS.SHOP_VISITS_COUNT) + `${targetId}:${dateKey}`;
    const hllKey = (type === 'product' ? KEYS.PRODUCT_VIEWS_HLL : KEYS.SHOP_VISITS_HLL) + `${targetId}:${dateKey}`;

    pipeline.get(countKey);
    pipeline.pfcount(hllKey);
  }

  try {
    const pipelineResults = await pipeline.exec();

    for (let i = 0; i < days; i++) {
      const date = new Date();
      date.setDate(date.getDate() - i);
      const dateKey = date.toISOString().split('T')[0];

      results.push({
        date: dateKey,
        total: parseInt(pipelineResults[i * 2][1]) || 0,
        unique: pipelineResults[i * 2 + 1][1] || 0
      });
    }

    return results;
  } catch (error) {
    logger.error(`Redis counter history failed: ${error.message}`);
    return null;
  }
}

// ============================================================================
// BATCH QUEUE OPERATIONS
// ============================================================================

/**
 * Add tracking event to batch queue for async processing
 * Reduces write pressure on PostgreSQL
 *
 * @param {Object} event - Tracking event data
 * @returns {Promise<boolean>}
 */
export async function queueTrackingEvent(event) {
  const redis = await getRedisClient();
  if (!redis) return false;

  try {
    const eventData = JSON.stringify({
      ...event,
      queuedAt: Date.now()
    });

    await redis.lpush(KEYS.BATCH_QUEUE, eventData);
    return true;
  } catch (error) {
    logger.error(`Redis queue push failed: ${error.message}`);
    return false;
  }
}

/**
 * Get batch of events for processing
 * Uses RPOP for FIFO processing
 *
 * @param {number} batchSize - Number of events to fetch
 * @returns {Promise<Array>}
 */
export async function getBatchEvents(batchSize = 100) {
  const redis = await getRedisClient();
  if (!redis) return [];

  try {
    // Use LRANGE + LTRIM for atomic batch retrieval
    const lockKey = KEYS.BATCH_QUEUE + ':lock';
    const locked = await redis.set(lockKey, '1', 'EX', TTL.BATCH_LOCK, 'NX');

    if (!locked) {
      return []; // Another worker is processing
    }

    const events = await redis.lrange(KEYS.BATCH_QUEUE, -batchSize, -1);

    if (events.length > 0) {
      await redis.ltrim(KEYS.BATCH_QUEUE, 0, -(events.length + 1));
    }

    await redis.del(lockKey);

    return events.map(e => {
      try {
        return JSON.parse(e);
      } catch {
        return null;
      }
    }).filter(Boolean);

  } catch (error) {
    logger.error(`Redis batch get failed: ${error.message}`);
    return [];
  }
}

/**
 * Get queue length for monitoring
 * @returns {Promise<number>}
 */
export async function getQueueLength() {
  const redis = await getRedisClient();
  if (!redis) return 0;

  try {
    return await redis.llen(KEYS.BATCH_QUEUE);
  } catch (error) {
    return 0;
  }
}

// ============================================================================
// CLEANUP & HEALTH
// ============================================================================

/**
 * Health check for Redis connection
 * @returns {Promise<{available: boolean, latency: number}>}
 */
export async function healthCheck() {
  const start = Date.now();
  const redis = await getRedisClient();

  if (!redis) {
    return { available: false, latency: -1 };
  }

  try {
    await redis.ping();
    return {
      available: true,
      latency: Date.now() - start
    };
  } catch (error) {
    return { available: false, latency: -1 };
  }
}

/**
 * Close Redis connection gracefully
 */
export async function closeConnection() {
  if (redisClient) {
    await redisClient.quit();
    redisClient = null;
    isRedisConnected = false;
    logger.info('Redis connection closed');
  }
}

// ============================================================================
// EXPORTS
// ============================================================================

export default {
  isRedisAvailable,
  checkDeduplication,
  markAsTracked,
  incrementCounter,
  getCounter,
  getCounterHistory,
  queueTrackingEvent,
  getBatchEvents,
  getQueueLength,
  healthCheck,
  closeConnection,
  KEYS,
  TTL
};
