/**
 * 🔴 REDIS CONFIGURATION - Phase 6
 *
 * Unified Redis client for cache, locks, rate limiting, and queues.
 * Graceful fallback: app works without Redis, just slower.
 */

import Redis from 'ioredis';
import { logger } from './logger.js';

type RedisClient = {
  on(event: string, listener: (...args: any[]) => void): void;
  connect(): Promise<void>;
  get(key: string): Promise<string | null>;
  setex(key: string, ttlSeconds: number, value: string): Promise<unknown>;
  del(...keys: string[]): Promise<number>;
  keys(pattern: string): Promise<string[]>;
  set(key: string, value: string, mode: 'EX', ttlSeconds: number, condition: 'NX'): Promise<'OK' | null | string>;
  expire(key: string, ttlSeconds: number): Promise<number>;
  ping(): Promise<string>;
  quit(): Promise<string>;
  eval(script: string, numKeys: number, ...args: Array<string | number>): Promise<any>;
  multi(): {
    incr(key: string): unknown;
    ttl(key: string): unknown;
    exec(): Promise<Array<[unknown, unknown]>>;
  };
};

// URL unique d'un Redis managé (Upstash / Redis Cloud / ElastiCache…).
// Format : redis://:password@host:port  ou  rediss://… (TLS, géré auto par ioredis)
const REDIS_URL = process.env.REDIS_URL || process.env.UPSTASH_REDIS_URL || '';

// Redis est activé si : explicitement (REDIS_ENABLED=true) OU une URL managée est
// fournie OU on est en production. Sinon désactivé (fallback mémoire) pour le dev.
const REDIS_ENABLED =
  (process.env.REDIS_ENABLED ?? ((REDIS_URL || process.env.NODE_ENV === 'production') ? 'true' : 'false')) === 'true';

// ==================== CONFIG ====================

const REDIS_CONFIG = {
  host: process.env.REDIS_HOST || 'localhost',
  port: parseInt(process.env.REDIS_PORT || '6379'),
  password: process.env.REDIS_PASSWORD || undefined,
  db: parseInt(process.env.REDIS_DB || '0'),
  maxRetriesPerRequest: 3,
  retryStrategy: (times: number) => {
    if (times > 10) {
      logger.error('Redis: max retries reached, using fallback');
      return null;
    }
    return Math.min(times * 200, 5000);
  },
  enableOfflineQueue: true,
  connectTimeout: 5000,
  commandTimeout: 2000,
  keepAlive: 30000,
  lazyConnect: true,
};

// ==================== SINGLETON ====================

let client: RedisClient | null = null;
let isConnected = false;
let connectAttempts = 0;
const MAX_ATTEMPTS = 5;
let disabledLogged = false;
let fallbackLogged = false;

function logFallbackOnce(message: string): void {
  if (fallbackLogged) return;
  fallbackLogged = true;
  logger.warn(message);
}

export async function getRedis(): Promise<RedisClient | null> {
  if (!REDIS_ENABLED) {
    if (!disabledLogged) {
      disabledLogged = true;
      logger.info('Redis disabled (REDIS_ENABLED=false), using fallback mode');
    }
    return null;
  }

  if (client && isConnected) return client;
  if (connectAttempts >= MAX_ATTEMPTS) return null;

  try {
    connectAttempts++;
    if (!client) {
      // URL managée prioritaire ; sinon host/port/password locaux
      client = (REDIS_URL
        ? new (Redis as any)(REDIS_URL, {
            lazyConnect: true,
            maxRetriesPerRequest: REDIS_CONFIG.maxRetriesPerRequest,
            retryStrategy: REDIS_CONFIG.retryStrategy,
            connectTimeout: REDIS_CONFIG.connectTimeout,
            commandTimeout: REDIS_CONFIG.commandTimeout,
          })
        : new (Redis as any)(REDIS_CONFIG)) as RedisClient;
      client.on('connect', () => { isConnected = true; connectAttempts = 0; fallbackLogged = false; logger.info('✅ Redis connected'); });
      client.on('error', (_err) => {
        isConnected = false;
        logFallbackOnce('Redis unavailable, continuing in fallback mode');
      });
      client.on('close', () => { isConnected = false; });
    }
    await client.connect();
    return client;
  } catch (err: any) {
    logFallbackOnce(`Redis connect failed (attempt ${connectAttempts}), fallback mode enabled`);
    return null;
  }
}

export function isRedisConnected(): boolean {
  return isConnected && client !== null;
}

// ==================== CACHE WRAPPER ====================

export const cache = {
  /**
   * Get cached value. Returns null if Redis unavailable or key missing.
   */
  async get<T = any>(key: string): Promise<T | null> {
    const redis = await getRedis();
    if (!redis) return null;
    try {
      const val = await redis.get(`cache:${key}`);
      return val ? JSON.parse(val) : null;
    } catch { return null; }
  },

  /**
   * Set cached value with TTL in seconds.
   */
  async set(key: string, value: any, ttlSeconds: number = 300): Promise<boolean> {
    const redis = await getRedis();
    if (!redis) return false;
    try {
      await redis.setex(`cache:${key}`, ttlSeconds, JSON.stringify(value));
      return true;
    } catch { return false; }
  },

  /**
   * Invalidate a cache key.
   */
  async del(key: string): Promise<boolean> {
    const redis = await getRedis();
    if (!redis) return false;
    try {
      await redis.del(`cache:${key}`);
      return true;
    } catch { return false; }
  },

  /**
   * Invalidate all keys matching a pattern.
   */
  async invalidatePattern(pattern: string): Promise<number> {
    const redis = await getRedis();
    if (!redis) return 0;
    try {
      const keys = await redis.keys(`cache:${pattern}`);
      if (keys.length > 0) await redis.del(...keys);
      return keys.length;
    } catch { return 0; }
  },

  /**
   * Cache-aside : renvoie la valeur en cache, sinon exécute `producer()`, met en cache
   * et renvoie. Si Redis est absent → exécute `producer()` directement (aucun cache, mais
   * comportement identique). Ne met JAMAIS en cache une valeur null/undefined (évite de
   * figer une absence transitoire). Tout échec cache est silencieux (best-effort).
   */
  async getOrSet<T>(key: string, ttlSeconds: number, producer: () => Promise<T>): Promise<T> {
    const cached = (await this.get(key)) as T | null;
    if (cached !== null && cached !== undefined) return cached;
    const fresh = await producer();
    if (fresh !== null && fresh !== undefined) {
      await this.set(key, fresh, ttlSeconds);
    }
    return fresh;
  },
};

// ==================== DISTRIBUTED LOCKS ====================

export const locks = {
  /**
   * Acquire a distributed lock. Returns true if acquired.
   * Uses SETNX with TTL to prevent deadlocks.
   */
  async acquire(lockName: string, ttlSeconds: number = 30): Promise<boolean> {
    const redis = await getRedis();
    if (!redis) return true; // Fail-open if no Redis
    try {
      const result = await redis.set(`lock:${lockName}`, Date.now().toString(), 'EX', ttlSeconds, 'NX');
      return result === 'OK';
    } catch { return true; }
  },

  /**
   * Release a distributed lock.
   */
  async release(lockName: string): Promise<void> {
    const redis = await getRedis();
    if (!redis) return;
    try {
      await redis.del(`lock:${lockName}`);
    } catch { /* ignore */ }
  },

  /**
   * Execute a function with a distributed lock.
   * If lock cannot be acquired, throws an error.
   */
  async withLock<T>(lockName: string, fn: () => Promise<T>, ttlSeconds: number = 30): Promise<T> {
    const acquired = await locks.acquire(lockName, ttlSeconds);
    if (!acquired) {
      throw new Error(`Could not acquire lock: ${lockName}`);
    }
    try {
      return await fn();
    } finally {
      await locks.release(lockName);
    }
  },
};

// ==================== RATE LIMITING (Redis-backed) ====================

// Rate-limit ATOMIQUE : INCR + EXPIRE-au-1er-hit dans UN seul appel (script Lua).
// Évite la fenêtre de course de l'ancien `multi(INCR,TTL)` + `expire` séparé, où
// une clé pouvait rester SANS TTL (crash/échec entre les deux) → IP bloquée pour
// toujours. Ici, le serveur Redis exécute le tout atomiquement.
const RATE_LIMIT_LUA = `
local current = redis.call('INCR', KEYS[1])
if current == 1 then
  redis.call('EXPIRE', KEYS[1], ARGV[1])
  return {current, tonumber(ARGV[1])}
end
local ttl = redis.call('TTL', KEYS[1])
if ttl < 0 then
  redis.call('EXPIRE', KEYS[1], ARGV[1])
  ttl = tonumber(ARGV[1])
end
return {current, ttl}
`;

export const redisRateLimit = {
  /**
   * Incrémente et vérifie le compteur de rate limit, ATOMIQUEMENT (Lua).
   * Retourne { allowed, remaining, resetAt }. resetAt === 0 ⇒ Redis indisponible
   * (le caller bascule alors sur le fallback mémoire).
   */
  async check(
    identifier: string,
    maxRequests: number,
    windowSeconds: number
  ): Promise<{ allowed: boolean; remaining: number; resetAt: number }> {
    const redis = await getRedis();
    if (!redis) return { allowed: true, remaining: maxRequests, resetAt: 0 };

    const key = `rl:${identifier}`;
    try {
      const res = await redis.eval(RATE_LIMIT_LUA, 1, key, String(windowSeconds));
      const count = Number(Array.isArray(res) ? res[0] : 0) || 0;
      const ttlRaw = Number(Array.isArray(res) ? res[1] : windowSeconds);
      const ttl = ttlRaw > 0 ? ttlRaw : windowSeconds;

      const allowed = count <= maxRequests;
      const remaining = Math.max(0, maxRequests - count);
      const resetAt = Date.now() + ttl * 1000;

      return { allowed, remaining, resetAt };
    } catch {
      return { allowed: true, remaining: maxRequests, resetAt: 0 };
    }
  },
};

// ==================== HEALTH CHECK ====================

export async function redisHealthCheck(): Promise<{ available: boolean; latencyMs: number }> {
  const start = Date.now();
  const redis = await getRedis();
  if (!redis) return { available: false, latencyMs: -1 };

  try {
    await redis.ping();
    return { available: true, latencyMs: Date.now() - start };
  } catch {
    return { available: false, latencyMs: -1 };
  }
}

// ==================== SHUTDOWN ====================

export async function closeRedis(): Promise<void> {
  if (client) {
    await client.quit();
    client = null;
    isConnected = false;
    logger.info('Redis connection closed');
  }
}

export default { getRedis, cache, locks, redisRateLimit, redisHealthCheck, closeRedis, isRedisConnected };
