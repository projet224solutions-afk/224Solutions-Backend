import { NextFunction, Response } from 'express';
import { logger } from '../config/logger.js';
import { supabaseAdmin } from '../config/supabase.js';
import { env } from '../config/env.js';
import { AuthenticatedRequest } from './auth.middleware.js';

type PermissionGuardOptions = {
  permissionKey: string;
  allowedRoles?: string[];
  allowInternalApiKey?: boolean;
};

const normalizeRole = (role: string | undefined | null): string => {
  return (role || '').toString().trim().toLowerCase();
};

const getPermissionCandidates = (permissionKey: string): string[] => {
  const normalized = permissionKey.trim();
  if (!normalized) return [];

  if (normalized.startsWith('pdg_')) {
    return [normalized, normalized.slice(4)];
  }

  return [normalized, `pdg_${normalized}`];
};

const hasGlobalRoleAccess = (role: string, allowedRoles: string[]): boolean => {
  return allowedRoles.includes(normalizeRole(role));
};

const findAgentIdByUser = async (userId: string): Promise<string | null> => {
  const { data: agent, error } = await supabaseAdmin
    .from('agents_management')
    .select('id, is_active')
    .eq('user_id', userId)
    .maybeSingle();

  if (error || !agent || !agent.is_active) {
    return null;
  }

  return agent.id;
};

const agentHasPermission = async (agentId: string, permissionKey: string): Promise<boolean> => {
  for (const candidate of getPermissionCandidates(permissionKey)) {
    const { data, error } = await supabaseAdmin.rpc('check_agent_permission' as any, {
      p_agent_id: agentId,
      p_permission_key: candidate,
    });

    if (error) {
      logger.warn(`[PermissionGuard] RPC check failed (${candidate}): ${error.message}`);
      continue;
    }

    if (Boolean(data)) {
      return true;
    }
  }

  return false;
};

export function requirePermissionOrRole(options: PermissionGuardOptions) {
  const {
    permissionKey,
    allowedRoles = ['admin', 'pdg', 'ceo'],
    allowInternalApiKey = false,
  } = options;

  return async (req: AuthenticatedRequest, res: Response, next: NextFunction): Promise<void> => {
    try {
      if (allowInternalApiKey) {
        const internalKey = req.headers['x-internal-api-key'] as string | undefined;
        if (env.INTERNAL_API_KEY && internalKey === env.INTERNAL_API_KEY) {
          next();
          return;
        }
      }

      if (!req.user) {
        res.status(401).json({ success: false, error: 'Authentification requise' });
        return;
      }

      const role = normalizeRole(req.user.role);
      if (hasGlobalRoleAccess(role, allowedRoles.map(normalizeRole))) {
        next();
        return;
      }

      const agentId = await findAgentIdByUser(req.user.id);
      if (!agentId) {
        res.status(403).json({ success: false, error: 'Permissions insuffisantes' });
        return;
      }

      const granted = await agentHasPermission(agentId, permissionKey);
      if (!granted) {
        logger.warn(`[PermissionGuard] Access denied user=${req.user.id} perm=${permissionKey}`);
        res.status(403).json({ success: false, error: 'Permission refusée' });
        return;
      }

      next();
    } catch (error: any) {
      logger.error(`[PermissionGuard] Error: ${error?.message || 'unknown'}`);
      res.status(500).json({ success: false, error: 'Erreur de vérification des permissions' });
    }
  };
}
