/**
 * 🚀 REAL-TIME ANALYTICS CONTROLLER
 *
 * HTTP endpoints for real-time analytics:
 * - GET /realtime/stats/:vendorId - Live stats
 * - GET /realtime/trending/:vendorId - Trending products
 * - POST /realtime/heartbeat - Keep vendor "online"
 */

import {
  getRealtimeStats,
  getTrendingProducts,
  markVendorOnline,
  healthCheck
} from '../services/realtime-analytics.service.js';
import { logger } from '../config/logger.js';

/**
 * GET /realtime/stats/:vendorId
 * Get real-time statistics for vendor dashboard
 */
export async function handleGetRealtimeStats(req, res) {
  try {
    const { vendorId } = req.params;
    const userId = req.user?.id;

    if (!userId) {
      return res.status(401).json({
        success: false,
        error: 'Authentication required'
      });
    }

    // Verify vendor ownership (basic check - could cache this)
    // Note: Full ownership check should be in middleware

    const stats = await getRealtimeStats(vendorId);

    // Mark vendor as online for targeted notifications
    await markVendorOnline(vendorId);

    return res.status(200).json({
      success: true,
      data: stats
    });

  } catch (error) {
    logger.error(`handleGetRealtimeStats error: ${error.message}`);
    return res.status(500).json({
      success: false,
      error: 'Failed to get real-time stats'
    });
  }
}

/**
 * GET /realtime/trending/:vendorId
 * Get trending products for a vendor
 */
export async function handleGetTrendingProducts(req, res) {
  try {
    const { vendorId } = req.params;
    const { limit = 5 } = req.query;

    if (!req.user?.id) {
      return res.status(401).json({
        success: false,
        error: 'Authentication required'
      });
    }

    const trending = await getTrendingProducts(vendorId, parseInt(limit));

    return res.status(200).json({
      success: true,
      data: {
        products: trending,
        generatedAt: new Date().toISOString()
      }
    });

  } catch (error) {
    logger.error(`handleGetTrendingProducts error: ${error.message}`);
    return res.status(500).json({
      success: false,
      error: 'Failed to get trending products'
    });
  }
}

/**
 * POST /realtime/heartbeat
 * Keep vendor marked as "online" (call every 2-3 minutes from dashboard)
 */
export async function handleHeartbeat(req, res) {
  try {
    const { vendorId } = req.body;

    if (!req.user?.id || !vendorId) {
      return res.status(400).json({
        success: false,
        error: 'vendorId required'
      });
    }

    await markVendorOnline(vendorId);

    return res.status(200).json({
      success: true,
      message: 'Heartbeat received'
    });

  } catch (error) {
    logger.error(`handleHeartbeat error: ${error.message}`);
    return res.status(500).json({ success: false });
  }
}

/**
 * GET /realtime/health
 * Health check for real-time subsystem
 */
export async function handleHealthCheck(req, res) {
  const health = await healthCheck();

  const status = health.status === 'healthy' ? 200 : 503;
  return res.status(status).json(health);
}

export default {
  handleGetRealtimeStats,
  handleGetTrendingProducts,
  handleHeartbeat,
  handleHealthCheck
};
