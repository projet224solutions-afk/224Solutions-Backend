/**
 * 📊 ANALYTICS MIDDLEWARE
 *
 * Middleware specific to analytics tracking:
 * - Rate limiting for tracking endpoints
 * - Input validation
 * - Anti-fraud helpers
 */

import { createRedisLimiter } from './rateLimiter.js';
import { logger } from '../config/logger.js';
import jwt from 'jsonwebtoken';
import { createClient } from '@supabase/supabase-js';

// Supabase client for optional auth
const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY
);

// ============================================================================
// RATE LIMITERS
// ============================================================================

/**
 * Rate limiter for tracking endpoints
 * More permissive since tracking happens frequently
 * 100 requests per minute per IP
 */
export const trackingRateLimiter = createRedisLimiter({
  max: 100,
  windowSeconds: 60,
  keyPrefix: 'track',
  label: 'tracking',
  message: 'Too many tracking requests, please slow down',
  code: 'RATE_LIMIT_EXCEEDED',
  skip: (req) => {
    const ip = String(req.ip || '').trim();
    const forwardedFor = String(req.headers['x-forwarded-for'] || '').split(',')[0].trim();
    const isLocalIp = ['::1', '127.0.0.1', '::ffff:127.0.0.1'].includes(ip)
      || ['::1', '127.0.0.1', '::ffff:127.0.0.1'].includes(forwardedFor);

    return req.method === 'OPTIONS'
      || req.path === '/health'
      || (process.env.NODE_ENV !== 'production' && isLocalIp);
  },
});

/**
 * Rate limiter for analytics retrieval endpoints
 * More strict since these are heavier queries
 * 30 requests per minute
 */
export const analyticsRateLimiter = createRedisLimiter({
  max: 30,
  windowSeconds: 60,
  keyPrefix: 'analytics-read',
  label: 'analytics',
  message: 'Too many analytics requests, please wait',
  code: 'RATE_LIMIT_EXCEEDED',
});

// ============================================================================
// VALIDATION MIDDLEWARE
// ============================================================================

/**
 * UUID validation regex
 */
const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/**
 * Validate tracking request input
 * @param {string} type - 'product' or 'shop'
 */
export function validateTrackingRequest(type) {
  return (req, res, next) => {
    const errors = [];

    if (type === 'product') {
      // Validate product ID
      if (!req.body.productId) {
        errors.push('productId is required');
      } else if (!UUID_REGEX.test(req.body.productId)) {
        errors.push('productId must be a valid UUID');
      }
    }

    if (type === 'shop') {
      // Validate vendor ID
      if (!req.body.vendorId) {
        errors.push('vendorId is required');
      } else if (!UUID_REGEX.test(req.body.vendorId)) {
        errors.push('vendorId must be a valid UUID');
      }
    }

    // Validate session ID if provided and user not authenticated
    const sessionId = req.headers['x-session-id'] || req.body?.sessionId;
    const isAuthenticated = !!req.user;

    if (!isAuthenticated && !sessionId) {
      errors.push('X-Session-ID header or sessionId in body is required for anonymous users');
    }

    if (sessionId && (typeof sessionId !== 'string' || sessionId.length > 128)) {
      errors.push('sessionId must be a string with max 128 characters');
    }

    // Validate optional country code
    if (req.body.countryCode && !/^[A-Z]{2}$/i.test(req.body.countryCode)) {
      errors.push('countryCode must be a 2-letter ISO code');
    }

    // Validate optional URLs
    if (req.body.refererUrl && req.body.refererUrl.length > 2048) {
      errors.push('refererUrl is too long (max 2048 characters)');
    }

    if (req.body.entryPage && req.body.entryPage.length > 255) {
      errors.push('entryPage is too long (max 255 characters)');
    }

    if (errors.length > 0) {
      return res.status(400).json({
        success: false,
        error: 'Validation failed',
        details: errors
      });
    }

    next();
  };
}

/**
 * Validate analytics retrieval request
 */
export function validateAnalyticsRequest(req, res, next) {
  const { vendorId } = req.params;
  const { productId, limit, offset } = req.query;
  const errors = [];

  // Validate vendor ID
  if (!vendorId) {
    errors.push('vendorId is required');
  } else if (!UUID_REGEX.test(vendorId)) {
    errors.push('vendorId must be a valid UUID');
  }

  // Validate optional product ID
  if (productId && !UUID_REGEX.test(productId)) {
    errors.push('productId must be a valid UUID');
  }

  // Validate pagination
  if (limit !== undefined) {
    const parsedLimit = parseInt(limit);
    if (isNaN(parsedLimit) || parsedLimit < 1 || parsedLimit > 100) {
      errors.push('limit must be a number between 1 and 100');
    }
  }

  if (offset !== undefined) {
    const parsedOffset = parseInt(offset);
    if (isNaN(parsedOffset) || parsedOffset < 0) {
      errors.push('offset must be a non-negative number');
    }
  }

  if (errors.length > 0) {
    return res.status(400).json({
      success: false,
      error: 'Validation failed',
      details: errors
    });
  }

  next();
}

// ============================================================================
// OPTIONAL JWT MIDDLEWARE
// ============================================================================

/**
 * Optional JWT verification
 * Sets req.user if valid token present, otherwise continues
 */
export async function optionalJWT(req, res, next) {
  try {
    const authHeader = req.headers.authorization;
    const token = authHeader && authHeader.split(' ')[1];

    if (!token) {
      // No token - continue as anonymous
      return next();
    }

    // Decode token
    const decoded = jwt.decode(token);

    if (!decoded) {
      // Invalid token format - continue as anonymous
      logger.debug('Invalid token format, continuing as anonymous');
      return next();
    }

    // Verify with Supabase
    const { data: { user }, error } = await supabase.auth.getUser(token);

    if (error || !user) {
      // Token invalid/expired - continue as anonymous
      logger.debug('Token verification failed, continuing as anonymous');
      return next();
    }

    // Set user on request
    req.user = {
      id: user.id,
      sub: user.id,
      email: user.email,
      aud: decoded.aud || 'authenticated'
    };

    next();
  } catch (error) {
    // Any error - continue as anonymous
    logger.debug(`Optional JWT error: ${error.message}`);
    next();
  }
}

export default {
  trackingRateLimiter,
  analyticsRateLimiter,
  validateTrackingRequest,
  validateAnalyticsRequest,
  optionalJWT
};
