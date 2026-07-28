/**
 * QR de paiement PERMANENT par vendeur (BLOC 1 du chantier QR).
 * Front-door vers le circuit payment_links existant : le token opaque résout le VENDEUR,
 * puis la page /p/<token> crée un paiement standard. Le vendeur est résolu par req.user.id.
 */
import { Router, Request, Response } from 'express';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { paymentRateLimit } from '../middlewares/routeRateLimiter.js';

const router = Router();

async function getVendorId(userId: string): Promise<string | null> {
  const { data } = await supabaseAdmin.from('vendors').select('id').eq('user_id', userId).maybeSingle();
  return (data as { id?: string } | null)?.id ?? null;
}

// GET /api/v2/vendor-qr/me — token QR permanent du vendeur (créé au 1er appel, stable ensuite).
router.get('/me', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const vid = await getVendorId(req.user!.id);
  if (!vid) { res.status(403).json({ success: false, error: 'Compte vendeur introuvable' }); return; }
  const { data, error } = await supabaseAdmin.rpc('vendor_qr_get_or_create', { p_vendor_id: vid });
  if (error) { res.status(400).json({ success: false, error: error.message }); return; }
  res.json({ success: true, data });
});

// POST /api/v2/vendor-qr/me/regenerate — révoque l'ancien token (autocollant inerte) + nouveau.
router.post('/me/regenerate', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const vid = await getVendorId(req.user!.id);
  if (!vid) { res.status(403).json({ success: false, error: 'Compte vendeur introuvable' }); return; }
  const { data, error } = await supabaseAdmin.rpc('vendor_qr_regenerate', { p_vendor_id: vid });
  if (error) { res.status(400).json({ success: false, error: error.message }); return; }
  logger.info(`[vendor-qr] ${req.user!.id} a régénéré son QR (vendor ${vid})`);
  res.json({ success: true, data });
});

// GET /api/v2/vendor-qr/resolve/:token — PUBLIC (page de scan). Rate-limité (token public).
// Renvoie { status: 'active'|'revoked'|'unknown', + contexte vendeur si actif }. Aucune donnée sensible.
router.get('/resolve/:token', paymentRateLimit, async (req: Request, res: Response): Promise<void> => {
  const token = String(req.params.token || '');
  if (!token || token.length < 16) { res.json({ success: true, data: { status: 'unknown' } }); return; }
  const { data, error } = await supabaseAdmin.rpc('vendor_qr_resolve', { p_token: token });
  if (error) { res.status(400).json({ success: false, error: error.message }); return; }
  res.json({ success: true, data });
});

export default router;
