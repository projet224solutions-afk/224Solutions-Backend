/**
 * 🔐 OWNER ROUTES
 * CEO/PDG-only endpoints for system oversight
 */

import { Router } from 'express';
import { authenticateToken } from '../middlewares/auth.js';
import { requireOwner, readOnlyAccess } from '../middlewares/owner.middleware.js';
import {
  handleGetLogs,
  handleGetStats,
  handleGetLogById,
  handleGetReasons
} from '../controllers/id-normalization-audit.controller.js';

const router = Router();

/**
 * All owner routes require:
 * 1. Valid JWT authentication
 * 2. Owner (CEO) role verification
 * 3. Read-only access (GET only)
 */
router.use(authenticateToken);
router.use(requireOwner);
router.use(readOnlyAccess);

// ============================================
// ID NORMALIZATION AUDIT ENDPOINTS
// ============================================

/**
 * GET /owner/id-normalization/logs
 *
 * Query params:
 * - page: number (default: 1)
 * - limit: number (default: 20, max: 100)
 * - role_type: string (filter by role)
 * - reason: string (filter by normalization reason)
 * - start_date: ISO date string
 * - end_date: ISO date string
 * - sort_by: string (default: 'created_at')
 * - sort_order: 'asc' | 'desc' (default: 'desc')
 *
 * Response:
 * {
 *   "success": true,
 *   "logs": [...],
 *   "pagination": {
 *     "page": 1,
 *     "limit": 20,
 *     "total": 150,
 *     "totalPages": 8,
 *     "hasNext": true,
 *     "hasPrev": false
 *   }
 * }
 */
router.get('/id-normalization/logs', handleGetLogs);

/**
 * GET /owner/id-normalization/stats
 *
 * Query params:
 * - start_date: ISO date string (optional)
 * - end_date: ISO date string (optional)
 *
 * Response:
 * {
 *   "success": true,
 *   "analytics": {
 *     "total_corrections": 150,
 *     "by_role": { "vendor": 80, "client": 50, "agent": 20 },
 *     "by_reason": { "duplicate_detected": 60, "format_invalid": 40, ... },
 *     "daily_trends": { "2026-01-15": 10, "2026-01-16": 15, ... },
 *     "period": { "start": "2026-01-01", "end": "now" }
 *   }
 * }
 */
router.get('/id-normalization/stats', handleGetStats);

/**
 * GET /owner/id-normalization/logs/:logId
 *
 * Response:
 * {
 *   "success": true,
 *   "log": {
 *     "id": "uuid",
 *     "user_id": "uuid",
 *     "role_type": "vendor",
 *     "original_id": "VEN-0001",
 *     "corrected_id": "VEN-0002",
 *     "reason": "duplicate_detected",
 *     "reason_details": { "conflicting_user_id": "uuid" },
 *     "auth_provider": "google",
 *     "ip_address": "192.168.1.1",
 *     "created_at": "2026-01-17T12:00:00Z"
 *   }
 * }
 */
router.get('/id-normalization/logs/:logId', handleGetLogById);

/**
 * GET /owner/id-normalization/reasons
 *
 * Response:
 * {
 *   "success": true,
 *   "reasons": [
 *     { "value": "duplicate_detected", "label": "Duplicate Detected" },
 *     ...
 *   ]
 * }
 */
router.get('/id-normalization/reasons', handleGetReasons);

export default router;
