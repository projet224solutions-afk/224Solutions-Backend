/**
 * 🚀 REAL-TIME ANALYTICS ROUTES
 *
 * Endpoints for live vendor dashboard data:
 * - GET /realtime/stats/:vendorId     - Live stats (views, visits, trends)
 * - GET /realtime/trending/:vendorId  - Trending products
 * - POST /realtime/heartbeat          - Keep vendor online
 * - GET /realtime/health              - System health check
 */

import { Router } from 'express';
import {
  handleGetRealtimeStats,
  handleGetTrendingProducts,
  handleHeartbeat,
  handleHealthCheck
} from '../controllers/realtime-analytics.controller.js';
import { verifyJWT } from '../middlewares/auth.middleware.js';

const router = Router();

// ============================================================================
// PUBLIC ENDPOINTS
// ============================================================================

/**
 * @route   GET /realtime/health
 * @desc    Health check for real-time subsystem
 * @access  Public
 */
router.get('/health', handleHealthCheck);

// ============================================================================
// AUTHENTICATED ENDPOINTS
// ============================================================================

/**
 * @route   GET /realtime/stats/:vendorId
 * @desc    Get real-time statistics for a vendor
 * @access  Private (vendor owner)
 *
 * @returns {
 *   success: true,
 *   data: {
 *     source: 'redis' | 'postgres_fallback',
 *     timestamp: ISO date,
 *     productViews: {
 *       thisHour: number,
 *       last5Minutes: number,
 *       velocity: number (projected views/hour),
 *       baseline: number (average for this hour),
 *       trend: number (% change vs baseline),
 *       status: 'spike' | 'hot' | 'up' | 'stable' | 'down' | 'cold'
 *     },
 *     shopVisits: { ... same structure ... }
 *   }
 * }
 */
router.get('/stats/:vendorId', verifyJWT, handleGetRealtimeStats);

/**
 * @route   GET /realtime/trending/:vendorId
 * @desc    Get trending products for a vendor
 * @access  Private (vendor owner)
 * @query   limit - Number of products (default: 5)
 *
 * @returns {
 *   success: true,
 *   data: {
 *     products: [{
 *       productId: UUID,
 *       name: string,
 *       imageUrl: string,
 *       viewsLastHour: number,
 *       isTrending: boolean
 *     }],
 *     generatedAt: ISO date
 *   }
 * }
 */
router.get('/trending/:vendorId', verifyJWT, handleGetTrendingProducts);

/**
 * @route   POST /realtime/heartbeat
 * @desc    Keep vendor marked as "online" for targeted notifications
 * @access  Private
 * @body    { vendorId: UUID }
 *
 * Call every 2-3 minutes from the dashboard to receive real-time notifications
 */
router.post('/heartbeat', verifyJWT, handleHeartbeat);

export default router;
