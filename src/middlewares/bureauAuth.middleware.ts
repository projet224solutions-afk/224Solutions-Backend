/**
 * 🔐 MIDDLEWARE — valide le JWT bureau et SCOPE la requête à son bureau.
 * À placer sur toutes les routes de données bureau. Le bureau_id provient du TOKEN,
 * jamais du corps/params de la requête → isolation inter-bureaux garantie côté serveur.
 */

import { Request, Response, NextFunction } from 'express';
import { verifyBureauToken, type BureauTokenPayload } from '../services/bureauAuth.service.js';

export interface BureauRequest extends Request {
  bureau?: BureauTokenPayload;
}

export function verifyBureauJWT(req: BureauRequest, res: Response, next: NextFunction): void {
  const authHeader = req.headers.authorization;
  const token = authHeader?.startsWith('Bearer ') ? authHeader.slice(7) : null;
  if (!token) {
    res.status(401).json({ success: false, error: 'Token bureau requis' });
    return;
  }
  const payload = verifyBureauToken(token);
  if (!payload) {
    res.status(403).json({ success: false, error: 'Session bureau invalide ou expirée' });
    return;
  }
  req.bureau = payload;
  next();
}
