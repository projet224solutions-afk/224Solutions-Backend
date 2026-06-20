/**
 * 🔐 OWNER MIDDLEWARE
 * Restricts access to CEO/PDG role only
 */

import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

/**
 * Middleware to verify owner (CEO) role
 * Must be used after authenticateToken middleware
 */
export async function requireOwner(req, res, next) {
  try {
    if (!req.user || !req.user.id) {
      return res.status(401).json({
        success: false,
        error: 'Authentication required'
      });
    }

    // Check if user has 'ceo' role in user_roles table
    const { data: roles, error } = await supabaseAdmin
      .from('user_roles')
      .select('role')
      .eq('user_id', req.user.id);

    if (error) {
      logger.error(`Error checking owner role: ${error.message}`);
      return res.status(500).json({
        success: false,
        error: 'Failed to verify permissions'
      });
    }

    const hasOwnerRole = roles?.some(r => r.role === 'ceo');

    if (!hasOwnerRole) {
      logger.warn(`Unauthorized owner access attempt by user ${req.user.id}`);
      return res.status(403).json({
        success: false,
        error: 'Access denied. Owner privileges required.'
      });
    }

    // Log successful owner access
    logger.info(`Owner access granted to user ${req.user.id}`);
    next();
  } catch (error) {
    logger.error(`Owner middleware error: ${error.message}`);
    return res.status(500).json({
      success: false,
      error: 'Authorization error'
    });
  }
}

/**
 * Middleware to ensure read-only access
 * Blocks any non-GET requests
 */
export function readOnlyAccess(req, res, next) {
  if (req.method !== 'GET') {
    logger.warn(`Blocked non-GET request to owner route: ${req.method} ${req.path}`);
    return res.status(405).json({
      success: false,
      error: 'Method not allowed. This endpoint is read-only.'
    });
  }
  next();
}

export default {
  requireOwner,
  readOnlyAccess
};
