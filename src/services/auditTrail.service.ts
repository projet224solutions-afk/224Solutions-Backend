/**
 * 🛡️ AUDIT TRAIL SERVICE - Phase 6
 *
 * Centralized security audit logging for all sensitive operations.
 * Logs to security_audit_trail table via service_role.
 */

import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

interface AuditLogEntry {
  actorId: string;
  actorType: 'user' | 'system' | 'webhook' | 'cron' | 'admin';
  action: string;
  resourceType: string;
  resourceId?: string;
  ip?: string;
  userAgent?: string;
  metadata?: Record<string, any>;
  riskLevel?: 'low' | 'medium' | 'high' | 'critical';
}

export const auditTrail = {
  /**
   * Log a security-relevant action.
   * Non-blocking: errors are logged but never thrown.
   */
  async log(entry: AuditLogEntry): Promise<void> {
    try {
      await supabaseAdmin
        .from('security_audit_trail')
        .insert({
          actor_id: entry.actorId,
          actor_type: entry.actorType,
          action: entry.action,
          resource_type: entry.resourceType,
          resource_id: entry.resourceId || null,
          ip_address: entry.ip || null,
          user_agent: entry.userAgent || null,
          metadata: entry.metadata || {},
          risk_level: entry.riskLevel || 'low',
        });
    } catch (err: any) {
      logger.warn(`Audit trail write failed: ${err.message}`);
    }
  },

  /**
   * Log from an Express request context.
   */
  async logFromRequest(req: any, action: string, resourceType: string, resourceId?: string, extra?: Record<string, any>): Promise<void> {
    await auditTrail.log({
      actorId: req.user?.id || 'anonymous',
      actorType: req.user?.id ? 'user' : 'system',
      action,
      resourceType,
      resourceId,
      ip: req.ip,
      userAgent: req.get('user-agent'),
      metadata: {
        ...extra,
        requestId: (req as any).requestId,
        method: req.method,
        path: req.originalUrl,
      },
    });
  },
};

export default auditTrail;
