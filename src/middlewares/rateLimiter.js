/**
 * 🛡️ RATE LIMITING MIDDLEWARE (Redis-backed, multi-instance safe)
 * Protection contre les abus et DDoS.
 *
 * Avant : `express-rate-limit` avec store EN MÉMOIRE (Map locale par instance)
 * → inefficace en multi-instance/serverless (chaque instance comptait à part →
 *   limite réelle = limite × nb d'instances) et fuite mémoire possible (DoS).
 *
 * Maintenant : compteur partagé via Redis (`config/redis` redisRateLimit, le
 * même backend que routeRateLimiter) → limite GLOBALE cohérente sur toutes les
 * instances. Fallback automatique en mémoire si Redis indisponible (fail-open
 * côté disponibilité : on ne bloque jamais le trafic à cause du limiteur).
 */

import { redisRateLimit } from '../config/redis.js';
import { logger } from '../config/logger.js';

const LOCALHOST_PATTERN = /^(localhost|127\.0\.0\.1)(:\d+)?$/i;
const LOCAL_IPS = new Set(['::1', '127.0.0.1', '::ffff:127.0.0.1']);

function isLocalDevelopmentRequest(req) {
  const ip = String(req.ip || '').trim();
  const forwardedFor = String(req.headers['x-forwarded-for'] || '')
    .split(',')[0]
    .trim();
  const host = String(req.headers.host || '').trim();

  const isLocalIp = LOCAL_IPS.has(ip) || LOCAL_IPS.has(forwardedFor);
  return process.env.NODE_ENV !== 'production' && (isLocalIp || LOCALHOST_PATTERN.test(host));
}

// ==================== Fallback mémoire (si Redis indisponible) ====================
// Borné + nettoyage périodique pour éviter toute fuite mémoire.
const memoryStore = new Map();
const MEMORY_MAX_KEYS = 100_000;

function memoryCheck(key, max, windowMs) {
  const now = Date.now();
  const entry = memoryStore.get(key);

  if (!entry || now > entry.resetAt) {
    if (memoryStore.size >= MEMORY_MAX_KEYS) {
      // Garde-fou anti-saturation : purge des entrées expirées
      for (const [k, v] of memoryStore) {
        if (now > v.resetAt) memoryStore.delete(k);
      }
    }
    memoryStore.set(key, { count: 1, resetAt: now + windowMs });
    return { allowed: true, remaining: max - 1, resetAt: now + windowMs };
  }

  entry.count++;
  return {
    allowed: entry.count <= max,
    remaining: Math.max(0, max - entry.count),
    resetAt: entry.resetAt,
  };
}

const cleanupTimer = setInterval(() => {
  const now = Date.now();
  for (const [key, entry] of memoryStore) {
    if (now > entry.resetAt) memoryStore.delete(key);
  }
}, 5 * 60 * 1000);
cleanupTimer.unref?.();

/**
 * Fabrique un middleware de rate limiting Redis-backed avec fallback mémoire.
 * @param {object} opts
 * @param {number} opts.max - requêtes autorisées par fenêtre
 * @param {number} opts.windowSeconds - durée de la fenêtre (s)
 * @param {string} opts.keyPrefix - préfixe de namespace du compteur
 * @param {string} opts.message - message d'erreur 429
 * @param {(req)=>boolean} [opts.skip] - prédicat pour ignorer la limite
 * @param {string} [opts.label] - libellé pour les logs
 */
export function createRedisLimiter({ max, windowSeconds, keyPrefix, message, skip, label, code }) {
  const windowMs = windowSeconds * 1000;

  return async function rateLimitMiddleware(req, res, next) {
    try {
      if (typeof skip === 'function' && skip(req)) {
        return next();
      }

      const ip = req.ip || req.headers['x-forwarded-for'] || 'unknown';
      const key = `${keyPrefix}:${ip}`;

      // Redis d'abord ; resetAt === 0 signale Redis indisponible → fallback mémoire
      let result = await redisRateLimit.check(key, max, windowSeconds);
      if (result.resetAt === 0) {
        result = memoryCheck(key, max, windowMs);
      }

      res.setHeader('RateLimit-Limit', max);
      res.setHeader('RateLimit-Remaining', result.remaining);
      res.setHeader('RateLimit-Reset', Math.ceil(result.resetAt / 1000));

      if (!result.allowed) {
        logger.warn(`Rate limit exceeded${label ? ` (${label})` : ''} for IP: ${ip} on ${req.path}`);
        res.status(429).json({
          success: false,
          error: message,
          retryAfter: windowSeconds,
          ...(code ? { code } : {}),
        });
        return;
      }

      next();
    } catch (err) {
      // Fail-open : un bug du limiteur ne doit jamais bloquer le trafic légitime
      logger.error(`Rate limiter error (fail-open): ${err?.message || err}`);
      next();
    }
  };
}

/**
 * Rate limiter global — par IP.
 * 10 000 requêtes/min par défaut (configurable via env).
 */
export const rateLimiter = createRedisLimiter({
  max: parseInt(process.env.RATE_LIMIT_MAX_REQUESTS, 10) || 10000,
  windowSeconds: Math.round((parseInt(process.env.RATE_LIMIT_WINDOW_MS, 10) || 60 * 1000) / 1000),
  keyPrefix: 'global',
  label: 'global',
  message: 'Trop de requêtes. Veuillez réessayer dans une minute.',
  skip: (req) => {
    if (isLocalDevelopmentRequest(req)) return true;
    return req.method === 'OPTIONS'
      || req.path === '/'
      || req.path === '/health'
      || req.path === '/healthz'
      || req.path === '/healthz.json'
      || req.path.startsWith('/assets')
      || req.path.startsWith('/favicon');
  },
});

/**
 * Rate limiter strict pour endpoints sensibles — par IP.
 * 10 requêtes / 15 min.
 */
export const strictRateLimiter = createRedisLimiter({
  max: 10,
  windowSeconds: 15 * 60,
  keyPrefix: 'strict',
  label: 'strict',
  message: 'Too many attempts, please try again later',
});

/**
 * Rate limiter pour uploads — par IP.
 * 20 uploads / heure.
 */
export const uploadRateLimiter = createRedisLimiter({
  max: 20,
  windowSeconds: 60 * 60,
  keyPrefix: 'upload',
  label: 'upload',
  message: 'Upload limit reached, please try again later',
});
