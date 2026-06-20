/**
 * 🔐 MIDDLEWARE — STEP-UP 2FA sur les opérations financières sensibles (admin/PDG)
 * ---------------------------------------------------------------------------
 * À placer APRÈS verifyJWT + requireRole(PDG_ROLES). Exige une vérification TOTP
 * récente (step-up) pour autoriser une action sensible (release/refund escrow,
 * gel de wallet, override de plafond AML, suppression d'utilisateur…).
 *
 * Fonctionnement :
 *  - Si l'admin a la 2FA ACTIVÉE :
 *      • un "grant" Redis valide (≤5 min, posé par une vérif TOTP récente) → passe ;
 *      • sinon, un header `X-MFA-Code` (TOTP 6 chiffres) valide → pose le grant, passe ;
 *      • sinon → 403 { code: 'MFA_REQUIRED' } (le front demande le code).
 *  - Si l'admin n'a PAS la 2FA :
 *      • ADMIN_MFA_ENFORCED=true  → 403 { code: 'MFA_ENROLLMENT_REQUIRED' } ;
 *      • ADMIN_MFA_ENFORCED=false → passe MAIS loggue un avertissement (transition
 *        non-bloquante, pour ne pas verrouiller les admins live avant enrôlement).
 *  - Lockout anti brute-force respecté (403 { code: 'MFA_LOCKED' }).
 */

import { Response, NextFunction } from 'express';
import { AuthenticatedRequest } from './auth.middleware.js';
import { cache } from '../config/redis.js';
import { env } from '../config/env.js';
import { logger } from '../config/logger.js';
import {
  getAdminMfa, isLocked, verifyTotp, decryptSecret,
  recordStepUpSuccess, recordFailure, logEvent,
} from '../services/totpMfa.service.js';

const STEP_UP_TTL_SECONDS = 300; // un step-up couvre 5 min d'actions sensibles
const grantKey = (userId: string) => `mfa-stepup:${userId}`;

export async function requireStepUpMFA(req: AuthenticatedRequest, res: Response, next: NextFunction): Promise<void> {
  try {
    const userId = req.user?.id;
    if (!userId) {
      res.status(401).json({ success: false, error: 'Authentification requise' });
      return;
    }

    const ip = (req.headers['x-forwarded-for'] as string)?.split(',')[0]?.trim() || req.ip;
    const userAgent = req.headers['user-agent'] as string | undefined;

    const row = await getAdminMfa(userId);

    // ── 2FA non activée → comportement piloté par le flag (non-bloquant par défaut) ──
    if (!row || !row.enabled) {
      if (env.ADMIN_MFA_ENFORCED) {
        res.status(403).json({
          success: false,
          code: 'MFA_ENROLLMENT_REQUIRED',
          error: 'Activez la 2FA pour effectuer cette opération sensible.',
        });
        return;
      }
      logger.warn(`[step-up-mfa] ⚠️ Op sensible SANS 2FA (transition) user=${userId} path=${req.originalUrl}`);
      next();
      return;
    }

    // ── Verrouillage anti brute-force ──
    if (isLocked(row)) {
      res.status(403).json({
        success: false,
        code: 'MFA_LOCKED',
        error: 'Trop de tentatives. Réessayez plus tard.',
        lockedUntil: row.locked_until,
      });
      return;
    }

    // ── Grant Redis encore valide → step-up déjà fait récemment ──
    const hasGrant = await cache.get<boolean>(grantKey(userId));
    if (hasGrant) {
      next();
      return;
    }

    // ── Sinon, exiger un code TOTP dans l'en-tête ──
    const code = (req.headers['x-mfa-code'] as string | undefined)?.trim();
    if (!code) {
      res.status(403).json({
        success: false,
        code: 'MFA_REQUIRED',
        error: 'Code 2FA requis pour cette opération sensible.',
      });
      return;
    }

    let valid = false;
    try {
      valid = verifyTotp(decryptSecret(row.secret_encrypted), code);
    } catch (e: any) {
      logger.error(`[step-up-mfa] vérification impossible user=${userId}: ${e?.message}`);
    }

    if (!valid) {
      const locked = await recordFailure(userId, row.failed_attempts);
      await logEvent(userId, locked ? 'lockout' : 'fail', false, { ip, userAgent, details: { path: req.originalUrl } });
      res.status(locked ? 403 : 401).json({
        success: false,
        code: locked ? 'MFA_LOCKED' : 'MFA_INVALID',
        error: locked ? 'Trop de tentatives. Compte 2FA verrouillé temporairement.' : 'Code 2FA invalide.',
      });
      return;
    }

    // Succès → poser le grant (best-effort si Redis absent : on revérifiera au prochain appel)
    await recordStepUpSuccess(userId);
    await cache.set(grantKey(userId), true, STEP_UP_TTL_SECONDS);
    await logEvent(userId, 'step_up', true, { ip, userAgent, details: { path: req.originalUrl } });
    next();
  } catch (error: any) {
    logger.error(`[step-up-mfa] erreur: ${error?.message}`);
    res.status(500).json({ success: false, error: 'Erreur de vérification 2FA' });
  }
}
