/**
 * 📊 ANALYTICS TRACKING CONTROLLER
 *
 * Handles HTTP requests for analytics tracking and retrieval
 */

import {
  trackProductView,
  trackShopVisit,
  getVendorAnalytics,
  getProductsAnalytics
} from '../services/analytics.service.js';
import { logger } from '../config/logger.js';

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

/**
 * Extract client IP from request
 * Handles proxies and load balancers
 * @param {Object} req
 * @returns {string}
 */
function getClientIP(req) {
  // Check for forwarded headers (when behind proxy/load balancer)
  const forwarded = req.headers['x-forwarded-for'];
  if (forwarded) {
    // Take the first IP in the chain (original client)
    return forwarded.split(',')[0].trim();
  }

  // Check for real IP header (Nginx)
  const realIP = req.headers['x-real-ip'];
  if (realIP) {
    return realIP;
  }

  // Fallback to connection remote address
  return req.connection?.remoteAddress ||
         req.socket?.remoteAddress ||
         req.ip ||
         '0.0.0.0';
}

/**
 * Extract session ID from request
 * @param {Object} req
 * @returns {string|null}
 */
function getSessionId(req) {
  // Check for session ID in header
  const headerSessionId = req.headers['x-session-id'];
  if (headerSessionId) {
    return headerSessionId;
  }

  // Check in body
  if (req.body?.sessionId) {
    return req.body.sessionId;
  }

  return null;
}

/**
 * Extract user ID from authenticated request
 * @param {Object} req
 * @returns {string|null}
 */
function getUserId(req) {
  return req.user?.id || req.user?.sub || null;
}

/**
 * Standardize error response
 * @param {Object} res
 * @param {number} status
 * @param {string} message
 * @param {string} code
 */
function errorResponse(res, status, message, code = null) {
  const response = {
    success: false,
    error: message
  };

  if (code) {
    response.code = code;
  }

  return res.status(status).json(response);
}

// ============================================================================
// TRACKING CONTROLLERS
// ============================================================================

/**
 * POST /track/product-view
 * Track a product view
 */
export async function handleProductView(req, res) {
  try {
    const { productId, refererUrl, countryCode, city, screenResolution } = req.body;

    // Validate required field
    if (!productId) {
      return errorResponse(res, 400, 'Product ID is required', 'MISSING_PRODUCT_ID');
    }

    // Get visitor identification
    const userId = getUserId(req);
    const sessionId = getSessionId(req);

    if (!userId && !sessionId) {
      return errorResponse(res, 400, 'Session ID is required for anonymous users', 'MISSING_SESSION');
    }

    // Extract request metadata
    const trackingData = {
      productId,
      userId,
      sessionId,
      ipAddress: getClientIP(req),
      userAgent: req.headers['user-agent'],
      refererUrl: refererUrl || req.headers['referer'],
      acceptLanguage: req.headers['accept-language'],
      screenResolution,
      countryCode,
      city
    };

    const result = await trackProductView(trackingData);

    if (!result.success && result.error !== 'Self-views are not counted') {
      const status = result.code === 'IP_BLOCKED' ? 403 : 400;
      return errorResponse(res, status, result.error, result.code);
    }

    // Return success (200 for new view, 200 for deduplicated - no distinction needed)
    return res.status(200).json({
      success: true,
      tracked: !result.deduplicated,
      message: result.deduplicated ? 'View already recorded today' : 'View tracked successfully'
    });

  } catch (error) {
    logger.error(`handleProductView error: ${error.message}`);
    return errorResponse(res, 500, 'Internal server error');
  }
}

/**
 * POST /track/shop-visit
 * Track a shop visit
 */
export async function handleShopVisit(req, res) {
  try {
    const { vendorId, refererUrl, countryCode, city, screenResolution, entryPage } = req.body;

    // Validate required field
    if (!vendorId) {
      return errorResponse(res, 400, 'Vendor ID is required', 'MISSING_VENDOR_ID');
    }

    // Get visitor identification
    const userId = getUserId(req);
    const sessionId = getSessionId(req);

    if (!userId && !sessionId) {
      return errorResponse(res, 400, 'Session ID is required for anonymous users', 'MISSING_SESSION');
    }

    // Extract request metadata
    const trackingData = {
      vendorId,
      userId,
      sessionId,
      ipAddress: getClientIP(req),
      userAgent: req.headers['user-agent'],
      refererUrl: refererUrl || req.headers['referer'],
      acceptLanguage: req.headers['accept-language'],
      screenResolution,
      countryCode,
      city,
      entryPage
    };

    const result = await trackShopVisit(trackingData);

    if (!result.success && result.error !== 'Self-visits are not counted') {
      const status = result.code === 'IP_BLOCKED' ? 403 : 400;
      return errorResponse(res, status, result.error, result.code);
    }

    // Return success
    return res.status(200).json({
      success: true,
      tracked: !result.deduplicated,
      message: result.deduplicated ? 'Visit already recorded today' : 'Visit tracked successfully'
    });

  } catch (error) {
    logger.error(`handleShopVisit error: ${error.message}`);
    return errorResponse(res, 500, 'Internal server error');
  }
}

// ============================================================================
// ANALYTICS RETRIEVAL CONTROLLERS
// ============================================================================

/**
 * GET /vendor/:vendorId/analytics/overview
 * Get aggregated shop analytics with trends
 *
 * Query params:
 *   - period: 'today' | 'week' | 'month' | 'custom' (default: 'week')
 *   - startDate: ISO date (required if period='custom')
 *   - endDate: ISO date (required if period='custom')
 *
 * Response:
 * {
 *   success: true,
 *   data: {
 *     vendor: { id, name },
 *     shopVisits: { total, unique, trend, byDevice },
 *     productViews: { total, unique, trend, byDevice },
 *     conversionRate: { current, previous, trend },
 *     topProducts: [...],
 *     dailyBreakdown: [...],
 *     period: { type, startDate, endDate },
 *     generatedAt: ISO
 *   }
 * }
 */
export async function handleGetVendorAnalytics(req, res) {
  try {
    const { vendorId } = req.params;
    const { period, startDate, endDate } = req.query;
    const userId = getUserId(req);

    if (!userId) {
      return errorResponse(res, 401, 'Authentication required');
    }

    if (!vendorId) {
      return errorResponse(res, 400, 'Vendor ID is required');
    }

    // Validate period
    const validPeriods = ['today', 'week', 'month', 'custom'];
    const selectedPeriod = validPeriods.includes(period) ? period : 'week';

    // Validate custom date range
    if (selectedPeriod === 'custom') {
      if (!startDate || !endDate) {
        return errorResponse(res, 400, 'startDate and endDate required for custom period');
      }

      const start = new Date(startDate);
      const end = new Date(endDate);

      if (isNaN(start.getTime()) || isNaN(end.getTime())) {
        return errorResponse(res, 400, 'Invalid date format');
      }

      if (start > end) {
        return errorResponse(res, 400, 'startDate must be before endDate');
      }

      // Limit to 90 days max
      const diffDays = (end - start) / (1000 * 60 * 60 * 24);
      if (diffDays > 90) {
        return errorResponse(res, 400, 'Date range cannot exceed 90 days');
      }
    }

    const result = await getVendorAnalytics(vendorId, userId, {
      period: selectedPeriod,
      startDate: selectedPeriod === 'custom' ? startDate : null,
      endDate: selectedPeriod === 'custom' ? endDate : null
    });

    if (!result.success) {
      const status = result.error === 'Unauthorized access' ? 403 : 400;
      return errorResponse(res, status, result.error);
    }

    return res.status(200).json(result);

  } catch (error) {
    logger.error(`handleGetVendorAnalytics error: ${error.message}`);
    return errorResponse(res, 500, 'Internal server error');
  }
}

/**
 * GET /vendor/:vendorId/analytics/products
 * Get product-level analytics with sorting and pagination
 *
 * Query params:
 *   - productId: UUID (optional, for single product)
 *   - limit: number (default: 50, max: 100)
 *   - offset: number (default: 0)
 *   - sortBy: 'views_total' | 'views_unique' | 'views_trend' | 'name' (default: 'views_total')
 *   - sortDir: 'asc' | 'desc' (default: 'desc')
 *
 * Response:
 * {
 *   success: true,
 *   data: {
 *     products: [{
 *       productId, name, imageUrl, category,
 *       views: { total, unique, trend },
 *       countryBreakdown: { US: 10, FR: 5 },
 *       peakHour: 14
 *     }],
 *     pagination: { limit, offset, total, hasMore },
 *     generatedAt: ISO
 *   }
 * }
 */
export async function handleGetProductsAnalytics(req, res) {
  try {
    const { vendorId } = req.params;
    const { productId, limit, offset, sortBy, sortDir } = req.query;
    const userId = getUserId(req);

    if (!userId) {
      return errorResponse(res, 401, 'Authentication required');
    }

    if (!vendorId) {
      return errorResponse(res, 400, 'Vendor ID is required');
    }

    // Validate sortBy
    const validSortFields = ['views_total', 'views_unique', 'views_trend', 'name'];
    const selectedSortBy = validSortFields.includes(sortBy) ? sortBy : 'views_total';

    // Validate sortDir
    const selectedSortDir = sortDir === 'asc' ? 'asc' : 'desc';

    const options = {
      productId: productId || null,
      limit: Math.min(parseInt(limit) || 50, 100),
      offset: parseInt(offset) || 0,
      sortBy: selectedSortBy,
      sortDir: selectedSortDir
    };

    const result = await getProductsAnalytics(vendorId, userId, options);

    if (!result.success) {
      const status = result.error === 'Unauthorized access' ? 403 : 400;
      return errorResponse(res, status, result.error);
    }

    return res.status(200).json(result);

  } catch (error) {
    logger.error(`handleGetProductsAnalytics error: ${error.message}`);
    return errorResponse(res, 500, 'Internal server error');
  }
}

export default {
  handleProductView,
  handleShopVisit,
  handleGetVendorAnalytics,
  handleGetProductsAnalytics
};
