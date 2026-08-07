/**
 * ⚠️ ERROR HANDLER - TypeScript version
 */

import { Request, Response, NextFunction } from 'express';
import { logger } from '../config/logger.js';
import { featureKeyForRoute } from '../services/featureManifest.js';
import { recordFeatureError } from '../services/featureErrorRate.service.js';

export function errorHandler(err: any, req: Request, res: Response, _next: NextFunction): void {
  // 👻 §8.3 — chaque erreur est TAGUÉE par fonctionnalité (manifeste) et comptée dans la
  // fenêtre glissante 5 min : un pic ouvre un incident AVANT le prochain passage de sonde.
  // 100 % en mémoire, jamais bloquant : le chemin d'erreur ne doit rien coûter.
  try {
    const route = `${req.method.toUpperCase()} ${(req.baseUrl || '') + (req.route?.path || req.path || '')}`;
    recordFeatureError(featureKeyForRoute(req.method, (req.baseUrl || '') + (req.path || '')), route);
  } catch { /* la surveillance ne casse jamais la réponse */ }

  logger.error('Error occurred:', {
    error: err.message,
    stack: err.stack,
    path: req.path,
    method: req.method,
    ip: req.ip
  });

  if (err.name === 'ValidationError') {
    res.status(400).json({ success: false, error: 'Validation error', details: err.errors });
    return;
  }

  if (err.name === 'JsonWebTokenError') {
    res.status(401).json({ success: false, error: 'Invalid token' });
    return;
  }

  if (err.name === 'TokenExpiredError') {
    res.status(401).json({ success: false, error: 'Token expired' });
    return;
  }

  if (err instanceof SyntaxError && (err as any).status === 400 && 'body' in err) {
    res.status(400).json({ success: false, error: 'Invalid JSON' });
    return;
  }

  const statusCode = err.statusCode || 500;

  // 🔒 Ne JAMAIS exposer err.message / err.stack au client (fuite de noms de tables, contraintes,
  // colonnes PostgreSQL), quel que soit NODE_ENV — qui vaut 'development' par DÉFAUT, donc non
  // fiable en prod. Le détail EST journalisé côté serveur (logger.error ci-dessus). Une route qui
  // veut renvoyer un message sûr le fait EXPLICITEMENT via err.publicMessage. Codes HTTP conservés.
  const publicMessage =
    typeof err.publicMessage === 'string' && err.publicMessage.trim()
      ? err.publicMessage
      : statusCode >= 500
        ? 'Internal server error'
        : 'Request could not be processed';

  res.status(statusCode).json({ success: false, error: publicMessage });
}
