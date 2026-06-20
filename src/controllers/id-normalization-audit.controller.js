/**
 * 🔐 ID NORMALIZATION AUDIT CONTROLLER
 * Owner-only read access to ID normalization logs
 */

import {
  getNormalizationLogs,
  getNormalizationStats,
  getNormalizationLogById,
  NORMALIZATION_REASONS
} from '../services/id-normalization-audit.service.js';
import { logger } from '../config/logger.js';

/**
 * GET /owner/id-normalization/logs
 * Paginated list of normalization logs with filters
 */
export async function handleGetLogs(req, res) {
  try {
    const {
      page = 1,
      limit = 20,
      role_type,
      reason,
      start_date,
      end_date,
      sort_by = 'created_at',
      sort_order = 'desc'
    } = req.query;

    // Validate limit
    const parsedLimit = Math.min(Math.max(parseInt(limit) || 20, 1), 100);
    const parsedPage = Math.max(parseInt(page) || 1, 1);

    // Validate reason if provided
    if (reason && !NORMALIZATION_REASONS.includes(reason)) {
      return res.status(400).json({
        success: false,
        error: `Invalid reason. Valid values: ${NORMALIZATION_REASONS.join(', ')}`
      });
    }

    const result = await getNormalizationLogs({
      page: parsedPage,
      limit: parsedLimit,
      roleType: role_type,
      reason,
      startDate: start_date,
      endDate: end_date,
      sortBy: sort_by,
      sortOrder: sort_order
    });

    if (!result.success) {
      return res.status(500).json(result);
    }

    logger.info(`Owner ${req.user.id} accessed normalization logs (page ${parsedPage})`);

    return res.json({
      success: true,
      ...result.data
    });
  } catch (error) {
    logger.error(`Error in handleGetLogs: ${error.message}`);
    return res.status(500).json({
      success: false,
      error: 'Internal server error'
    });
  }
}

/**
 * GET /owner/id-normalization/stats
 * Analytics overview of normalizations
 */
export async function handleGetStats(req, res) {
  try {
    const { start_date, end_date } = req.query;

    const result = await getNormalizationStats({
      startDate: start_date,
      endDate: end_date
    });

    if (!result.success) {
      return res.status(500).json(result);
    }

    logger.info(`Owner ${req.user.id} accessed normalization stats`);

    return res.json({
      success: true,
      analytics: result.data
    });
  } catch (error) {
    logger.error(`Error in handleGetStats: ${error.message}`);
    return res.status(500).json({
      success: false,
      error: 'Internal server error'
    });
  }
}

/**
 * GET /owner/id-normalization/logs/:logId
 * Single log entry details
 */
export async function handleGetLogById(req, res) {
  try {
    const { logId } = req.params;

    if (!logId) {
      return res.status(400).json({
        success: false,
        error: 'Log ID is required'
      });
    }

    const result = await getNormalizationLogById(logId);

    if (!result.success) {
      return res.status(404).json({
        success: false,
        error: 'Log entry not found'
      });
    }

    logger.info(`Owner ${req.user.id} accessed log ${logId}`);

    return res.json({
      success: true,
      log: result.data
    });
  } catch (error) {
    logger.error(`Error in handleGetLogById: ${error.message}`);
    return res.status(500).json({
      success: false,
      error: 'Internal server error'
    });
  }
}

/**
 * GET /owner/id-normalization/reasons
 * List of valid normalization reasons
 */
export async function handleGetReasons(req, res) {
  return res.json({
    success: true,
    reasons: NORMALIZATION_REASONS.map(reason => ({
      value: reason,
      label: reason.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase())
    }))
  });
}

export default {
  handleGetLogs,
  handleGetStats,
  handleGetLogById,
  handleGetReasons
};
