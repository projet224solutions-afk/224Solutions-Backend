/**
 * 🔐 ID NORMALIZATION AUDIT SERVICE
 * Logs and retrieves ID normalization events
 * Owner-only access for audit purposes
 */

import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

/**
 * Valid normalization reasons
 */
const NORMALIZATION_REASONS = [
  'duplicate_detected',
  'format_invalid',
  'prefix_mismatch',
  'sequence_gap',
  'collision_resolved',
  'manual_override',
  'migration_fix'
];

/**
 * Log an ID normalization event
 * Called automatically during signup when ID correction occurs
 */
export async function logIdNormalization({
  userId,
  roleType,
  originalId,
  correctedId,
  reason,
  reasonDetails = {},
  authProvider = null,
  ipAddress = null,
  userAgent = null,
  metadata = {}
}) {
  try {
    if (!NORMALIZATION_REASONS.includes(reason)) {
      throw new Error(`Invalid normalization reason: ${reason}`);
    }

    const { data, error } = await supabaseAdmin
      .from('id_normalization_logs')
      .insert({
        user_id: userId,
        role_type: roleType,
        original_id: originalId,
        corrected_id: correctedId,
        reason,
        reason_details: reasonDetails,
        auth_provider: authProvider,
        ip_address: ipAddress,
        user_agent: userAgent,
        metadata
      })
      .select()
      .single();

    if (error) throw error;

    logger.info(`ID normalization logged: ${originalId} -> ${correctedId} (${reason})`);
    return { success: true, logId: data.id };
  } catch (error) {
    logger.error(`Failed to log ID normalization: ${error.message}`);
    return { success: false, error: error.message };
  }
}

/**
 * Get paginated normalization logs (owner-only)
 */
export async function getNormalizationLogs({
  page = 1,
  limit = 20,
  roleType = null,
  reason = null,
  startDate = null,
  endDate = null,
  sortBy = 'created_at',
  sortOrder = 'desc'
}) {
  try {
    const offset = (page - 1) * limit;

    let query = supabaseAdmin
      .from('id_normalization_logs')
      .select('*', { count: 'exact' });

    // Apply filters
    if (roleType) {
      query = query.eq('role_type', roleType);
    }
    if (reason) {
      query = query.eq('reason', reason);
    }
    if (startDate) {
      query = query.gte('created_at', startDate);
    }
    if (endDate) {
      query = query.lte('created_at', endDate);
    }

    // Apply sorting and pagination
    query = query
      .order(sortBy, { ascending: sortOrder === 'asc' })
      .range(offset, offset + limit - 1);

    const { data, error, count } = await query;

    if (error) throw error;

    return {
      success: true,
      data: {
        logs: data,
        pagination: {
          page,
          limit,
          total: count,
          totalPages: Math.ceil(count / limit),
          hasNext: offset + limit < count,
          hasPrev: page > 1
        }
      }
    };
  } catch (error) {
    logger.error(`Failed to fetch normalization logs: ${error.message}`);
    return { success: false, error: error.message };
  }
}

/**
 * Get normalization analytics/stats (owner-only)
 */
export async function getNormalizationStats({
  startDate = null,
  endDate = null
}) {
  try {
    // Get stats by role type
    let roleQuery = supabaseAdmin
      .from('id_normalization_logs')
      .select('role_type');

    if (startDate) roleQuery = roleQuery.gte('created_at', startDate);
    if (endDate) roleQuery = roleQuery.lte('created_at', endDate);

    const { data: allLogs, error: logsError } = await roleQuery;
    if (logsError) throw logsError;

    // Aggregate stats
    const byRole = {};
    const byReason = {};

    for (const log of allLogs) {
      byRole[log.role_type] = (byRole[log.role_type] || 0) + 1;
    }

    // Get stats by reason
    let reasonQuery = supabaseAdmin
      .from('id_normalization_logs')
      .select('reason');

    if (startDate) reasonQuery = reasonQuery.gte('created_at', startDate);
    if (endDate) reasonQuery = reasonQuery.lte('created_at', endDate);

    const { data: reasonLogs, error: reasonError } = await reasonQuery;
    if (reasonError) throw reasonError;

    for (const log of reasonLogs) {
      byReason[log.reason] = (byReason[log.reason] || 0) + 1;
    }

    // Get recent trends (last 7 days)
    const sevenDaysAgo = new Date();
    sevenDaysAgo.setDate(sevenDaysAgo.getDate() - 7);

    const { data: recentLogs, error: recentError } = await supabaseAdmin
      .from('id_normalization_logs')
      .select('created_at, role_type, reason')
      .gte('created_at', sevenDaysAgo.toISOString())
      .order('created_at', { ascending: true });

    if (recentError) throw recentError;

    // Group by day
    const dailyTrends = {};
    for (const log of recentLogs) {
      const day = log.created_at.split('T')[0];
      dailyTrends[day] = (dailyTrends[day] || 0) + 1;
    }

    return {
      success: true,
      data: {
        total_corrections: allLogs.length,
        by_role: byRole,
        by_reason: byReason,
        daily_trends: dailyTrends,
        period: {
          start: startDate || 'all_time',
          end: endDate || 'now'
        }
      }
    };
  } catch (error) {
    logger.error(`Failed to fetch normalization stats: ${error.message}`);
    return { success: false, error: error.message };
  }
}

/**
 * Get a single log entry by ID (owner-only)
 */
export async function getNormalizationLogById(logId) {
  try {
    const { data, error } = await supabaseAdmin
      .from('id_normalization_logs')
      .select('*')
      .eq('id', logId)
      .single();

    if (error) throw error;

    return { success: true, data };
  } catch (error) {
    logger.error(`Failed to fetch log by ID: ${error.message}`);
    return { success: false, error: error.message };
  }
}

export default {
  logIdNormalization,
  getNormalizationLogs,
  getNormalizationStats,
  getNormalizationLogById,
  NORMALIZATION_REASONS
};
