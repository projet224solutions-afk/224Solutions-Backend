/**
 * 📊 REQUEST LOGGER — Phase 5
 * Structured logging with correlation ID and domain classification
 */

import { Request, Response, NextFunction } from 'express';
import { logger } from '../config/logger.js';
import { AuthenticatedRequest } from './auth.middleware.js';

const DOMAIN_MAP: Record<string, string> = {
  '/api/orders': 'orders',
  '/api/pos': 'pos',
  '/api/inventory': 'inventory',
  '/api/payments': 'payments',
  '/api/subscriptions': 'subscriptions',
  '/api/products': 'products',
  '/api/vendors': 'vendors',
  '/api/wallet': 'wallet',
  '/api/v2/wallet': 'wallet',
};

function resolveDomain(path: string): string {
  for (const [prefix, domain] of Object.entries(DOMAIN_MAP)) {
    if (path.startsWith(prefix)) return domain;
  }
  return 'general';
}

export function requestLogger(req: Request, res: Response, next: NextFunction): void {
  const start = Date.now();

  res.on('finish', () => {
    const duration = Date.now() - start;
    const ip = req.ip || 'unknown';
    const userId = (req as AuthenticatedRequest).user?.id || 'anonymous';
    const requestId = (req as any).requestId || '-';
    const domain = resolveDomain(req.path);

    const meta = {
      requestId,
      domain,
      userId,
      ip,
      duration,
      statusCode: res.statusCode,
      method: req.method,
      path: req.path,
    };

    const logMessage = `[${domain}] ${req.method} ${req.path} - ${res.statusCode} - ${duration}ms`;

    if (res.statusCode >= 500) {
      logger.error(logMessage, meta);
    } else if (res.statusCode >= 400) {
      logger.warn(logMessage, meta);
    } else {
      logger.info(logMessage, meta);
    }
  });

  next();
}
