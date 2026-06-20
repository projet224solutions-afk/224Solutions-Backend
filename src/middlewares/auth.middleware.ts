/**
 * 🔐 AUTH MIDDLEWARE - TypeScript version
 * JWT verification via Supabase Auth
 * Consolidation des deux anciens middlewares (auth.js + auth.middleware.js)
 */

import { Request, Response, NextFunction } from 'express';
import jwt from 'jsonwebtoken';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { env } from '../config/env.js';

export interface AuthenticatedUser {
  id: string;
  email: string;
  role: string;
  profile: Record<string, any> | null;
  emailConfirmedAt?: string | null;
}

export interface AuthenticatedRequest extends Request {
  user?: AuthenticatedUser;
}

interface JwtFallbackPayload {
  sub: string;
  email?: string;
  role?: string;
  exp?: number;
  [key: string]: unknown;
}

function isTransientSupabaseAuthError(message: string): boolean {
  return /fetch failed|timeout|timed out|econnreset|connect timeout|network/i.test(message);
}

async function buildAuthenticatedUser(userId: string, email: string, fallbackRole?: string, emailConfirmedAt?: string | null): Promise<AuthenticatedUser> {
  const { data: profile } = await supabaseAdmin
    .from('profiles')
    .select('*')
    .eq('id', userId)
    .single();

  return {
    id: userId,
    email,
    role: profile?.role || fallbackRole || 'client',
    profile: profile || null,
    emailConfirmedAt: emailConfirmedAt ?? null,
  };
}

async function resolveUserFromToken(token: string): Promise<AuthenticatedUser | null> {
  const { data: { user }, error } = await supabaseAdmin.auth.getUser(token);

  if (!error && user) {
    return buildAuthenticatedUser(user.id, user.email || '', undefined, user.email_confirmed_at);
  }

  const errorMessage = String(error?.message || 'No user returned');
  if (!env.JWT_SECRET || !isTransientSupabaseAuthError(errorMessage)) {
    if (error || !user) {
      logger.warn(`Invalid token attempt: ${errorMessage}`);
    }
    return null;
  }

  try {
    const decoded = jwt.verify(token, env.JWT_SECRET) as JwtFallbackPayload;
    if (!decoded?.sub) {
      logger.warn('JWT fallback verification failed: missing subject');
      return null;
    }

    logger.warn(`Supabase auth unavailable, using local JWT fallback for ${decoded.sub}`);
    return buildAuthenticatedUser(decoded.sub, String(decoded.email || ''), typeof decoded.role === 'string' ? decoded.role : undefined, null);
  } catch (jwtError: any) {
    logger.warn(`Invalid token attempt after JWT fallback: ${jwtError?.message || jwtError}`);
    return null;
  }
}

/**
 * Vérifie le JWT Supabase et charge le profil utilisateur
 */
export async function verifyJWT(req: AuthenticatedRequest, res: Response, next: NextFunction): Promise<void> {
  try {
    const authHeader = req.headers.authorization;
    const token = authHeader?.startsWith('Bearer ') ? authHeader.slice(7) : null;

    if (!token) {
      res.status(401).json({
        success: false,
        error: 'Token d\'accès requis',
        message: 'Un token Bearer est requis dans le header Authorization'
      });
      return;
    }

    const authenticatedUser = await resolveUserFromToken(token);

    if (!authenticatedUser) {
      res.status(403).json({
        success: false,
        error: 'Token expiré ou invalide',
        message: 'Le token n\'est pas valide'
      });
      return;
    }

    req.user = authenticatedUser;

    logger.info(`Authenticated: ${authenticatedUser.id} (${authenticatedUser.email})`);
    next();
  } catch (error: any) {
    logger.error(`Auth middleware error: ${error.message}`);
    res.status(500).json({
      success: false,
      error: 'Erreur d\'authentification',
      message: 'Une erreur s\'est produite lors de la vérification du token'
    });
  }
}

/**
 * JWT optionnel - ne bloque pas si absent
 */
export async function optionalJWT(req: AuthenticatedRequest, res: Response, next: NextFunction): Promise<void> {
  const authHeader = req.headers.authorization;
  const token = authHeader?.startsWith('Bearer ') ? authHeader.slice(7) : null;

  if (!token) {
    return next();
  }

  try {
    const authenticatedUser = await resolveUserFromToken(token);
    if (authenticatedUser) {
      req.user = authenticatedUser;
    }
  } catch {
    // Silent fail - user remains anonymous
  }

  next();
}

/**
 * Vérifie les permissions par rôle
 */
export function requireRole(allowedRoles: string | string[]) {
  const roles = Array.isArray(allowedRoles) ? allowedRoles : [allowedRoles];
  return (req: AuthenticatedRequest, res: Response, next: NextFunction): void => {
    if (!req.user) {
      res.status(401).json({ success: false, error: 'Authentification requise' });
      return;
    }

    if (!roles.includes(req.user.role)) {
      logger.warn(`Access denied for ${req.user.id} - Required: ${roles.join(', ')}`);
      res.status(403).json({ success: false, error: 'Permissions insuffisantes' });
      return;
    }

    next();
  };
}

/**
 * Clé API interne (communication inter-backends)
 */
export function authenticateInternal(req: Request, res: Response, next: NextFunction): void {
  const apiKey = req.headers['x-internal-api-key'] as string;

  if (!apiKey) {
    res.status(401).json({ success: false, error: 'Internal API key required' });
    return;
  }

  if (!env.INTERNAL_API_KEY || apiKey !== env.INTERNAL_API_KEY) {
    logger.warn(`Invalid internal API key from IP: ${req.ip}`);
    res.status(403).json({ success: false, error: 'Invalid API key' });
    return;
  }

  next();
}
