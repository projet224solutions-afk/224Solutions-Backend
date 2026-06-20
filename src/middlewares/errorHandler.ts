/**
 * ⚠️ ERROR HANDLER - TypeScript version
 */

import { Request, Response, NextFunction } from 'express';
import { logger } from '../config/logger.js';
import { env } from '../config/env.js';

export function errorHandler(err: any, req: Request, res: Response, _next: NextFunction): void {
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
  const message = env.isProduction ? 'Internal server error' : err.message;

  res.status(statusCode).json({
    success: false,
    error: message,
    ...(!env.isProduction && { stack: err.stack })
  });
}
