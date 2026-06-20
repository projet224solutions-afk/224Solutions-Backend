/**
 * 📊 ANALYTICS ROUTES
 *
 * Endpoints for analytics tracking and retrieval:
 * - POST /track/product-view    (public/semi-public)
 * - POST /track/shop-visit      (public/semi-public)
 * - GET /vendor/:vendorId/analytics           (authenticated)
 * - GET /vendor/:vendorId/products/analytics  (authenticated)
 */

import { Router } from 'express';
import {
  handleProductView,
  handleShopVisit,
  handleGetVendorAnalytics,
  handleGetProductsAnalytics
} from '../controllers/analytics.controller.js';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import {
  trackingRateLimiter,
  analyticsRateLimiter,
  validateTrackingRequest,
  validateAnalyticsRequest,
  optionalJWT
} from '../middlewares/analytics.middleware.js';

const router = Router();

// ============================================================================
// TRACKING ENDPOINTS (Public - but with optional auth for better tracking)
// ============================================================================

/**
 * @route   POST /track/product-view
 * @desc    Track a product view
 * @access  Public (optional auth for authenticated users)
 * @body    { productId: UUID, sessionId?: string, refererUrl?: string, countryCode?: string }
 * @headers X-Session-ID for anonymous users
 */
router.post(
  '/track/product-view',
  trackingRateLimiter,
  optionalJWT,
  validateTrackingRequest('product'),
  handleProductView
);

/**
 * @route   POST /track/shop-visit
 * @desc    Track a shop/vendor page visit
 * @access  Public (optional auth for authenticated users)
 * @body    { vendorId: UUID, sessionId?: string, refererUrl?: string, countryCode?: string, entryPage?: string }
 * @headers X-Session-ID for anonymous users
 */
router.post(
  '/track/shop-visit',
  trackingRateLimiter,
  optionalJWT,
  validateTrackingRequest('shop'),
  handleShopVisit
);

// ============================================================================
// ANALYTICS RETRIEVAL ENDPOINTS (Authenticated - vendors only)
// ============================================================================

/**
 * @route   GET /vendor/:vendorId/analytics/overview
 * @desc    Get aggregated shop-level analytics with trends
 * @access  Private (vendor owner only)
 * @params  vendorId - The vendor's UUID
 * @query   period - 'today' | 'week' | 'month' | 'custom' (default: 'week')
 * @query   startDate - ISO date (required if period='custom')
 * @query   endDate - ISO date (required if period='custom')
 *
 * @returns {
 *   success: boolean,
 *   data: {
 *     vendor: { id, name },
 *     shopVisits: {
 *       total: number,
 *       unique: number,
 *       trend: number (percentage change vs previous period),
 *       byDevice: { desktop, mobile, tablet }
 *     },
 *     productViews: {
 *       total: number,
 *       unique: number,
 *       trend: number,
 *       byDevice: { desktop, mobile, tablet }
 *     },
 *     conversionRate: {
 *       current: number (percentage),
 *       previous: number,
 *       trend: number
 *     },
 *     topProducts: [{
 *       productId: UUID,
 *       name: string,
 *       imageUrl: string,
 *       views: number,
 *       uniqueViews: number
 *     }],
 *     dailyBreakdown: [{
 *       date: ISO date,
 *       shopVisits: number,
 *       productViews: number,
 *       uniqueVisitors: number
 *     }],
 *     period: { type, startDate, endDate },
 *     generatedAt: ISO date
 *   }
 * }
 */
router.get(
  '/vendor/:vendorId/analytics/overview',
  analyticsRateLimiter,
  verifyJWT,
  validateAnalyticsRequest,
  handleGetVendorAnalytics
);

/**
 * @route   GET /vendor/:vendorId/analytics/products
 * @desc    Get product-level analytics with sorting and pagination
 * @access  Private (vendor owner only)
 * @params  vendorId - The vendor's UUID
 * @query   productId? - Optional specific product UUID
 * @query   limit? - Number of products (default 50, max 100)
 * @query   offset? - Pagination offset (default 0)
 * @query   sortBy? - 'views_total' | 'views_unique' | 'views_trend' | 'name' (default: 'views_total')
 * @query   sortDir? - 'asc' | 'desc' (default: 'desc')
 *
 * @returns {
 *   success: boolean,
 *   data: {
 *     products: [{
 *       productId: UUID,
 *       name: string,
 *       imageUrl: string,
 *       category: string,
 *       views: {
 *         total: number,
 *         unique: number,
 *         trend: number (percentage change)
 *       },
 *       countryBreakdown: { US: 10, FR: 5, ... },
 *       peakHour: number (0-23)
 *     }],
 *     pagination: {
 *       limit: number,
 *       offset: number,
 *       total: number,
 *       hasMore: boolean
 *     },
 *     generatedAt: ISO date
 *   }
 * }
 */
router.get(
  '/vendor/:vendorId/analytics/products',
  analyticsRateLimiter,
  verifyJWT,
  validateAnalyticsRequest,
  handleGetProductsAnalytics
);

// Legacy route aliases (for backwards compatibility)
router.get('/vendor/:vendorId/analytics', analyticsRateLimiter, verifyJWT, validateAnalyticsRequest, handleGetVendorAnalytics);
router.get('/vendor/:vendorId/products/analytics', analyticsRateLimiter, verifyJWT, validateAnalyticsRequest, handleGetProductsAnalytics);

export default router;
