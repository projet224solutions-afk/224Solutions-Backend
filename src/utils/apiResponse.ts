import type { Response } from "express";

/**
 * Helpers du contrat d'API (voir docs/API_CONTRACT.md).
 * OBLIGATOIRE pour tout NOUVEAU endpoint Express. NE PAS migrer les routes existantes ici
 * (certains consommateurs frontend lisent encore un format à plat) — chantier séparé.
 */

/** Réponse de succès : HTTP 2xx + { success:true, data, meta? }. `data` est toujours présent. */
export function ok<T>(
  res: Response,
  data: T,
  meta?: { limit: number; offset: number; total: number },
  status = 200,
) {
  return res.status(status).json({ success: true, data, ...(meta ? { meta } : {}) });
}

/** Réponse d'échec : HTTP 4xx/5xx + { success:false, error, error_code?, details? }. `error` en FR. */
export function fail(
  res: Response,
  status: number,
  error: string,
  error_code?: string,
  details?: unknown,
) {
  return res.status(status).json({
    success: false,
    error,
    ...(error_code ? { error_code } : {}),
    ...(details !== undefined ? { details } : {}),
  });
}
