/**
 * ⚠️ ERROR HANDLER - TypeScript version
 */

import { Request, Response, NextFunction } from 'express';
import { logger } from '../config/logger.js';

export function errorHandler(err: any, req: Request, res: Response, _next: NextFunction): void {
  // Détails COMPLETS (stack incluse) loggués côté serveur UNIQUEMENT.
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

  // A2 — Refus CORS : 403 Forbidden propre (jamais un 500 verbeux).
  if (err.message === 'Not allowed by CORS') {
    res.status(403).json({ success: false, error: 'Origin not allowed' });
    return;
  }

  // A1 — Fail-safe : NE JAMAIS renvoyer stack, chemins de fichiers ni détails internes
  // au client, quelle que soit la valeur de NODE_ENV (le correctif ne dépend PAS d'un
  // NODE_ENV=production correct sur l'EC2). Les erreurs serveur (5xx) reçoivent un message
  // générique ; les erreurs client (4xx) applicatives gardent leur message métier (déjà sûr).
  const statusCode = typeof err.statusCode === 'number' ? err.statusCode : 500;
  const message = statusCode >= 500
    ? 'Internal server error'
    : (typeof err.message === 'string' ? err.message : 'Request error');

  res.status(statusCode).json({ success: false, error: message });
}
