/**
 * 🔧 SERVICES ARTISANS — transitions sensibles (Phase 0).
 * Les 2 actions money/gate-sensibles passent par le backend (RPC service_role) :
 *   - POST /quote/:id/accept       → le CLIENT accepte un devis (crée l'intervention).
 *   - POST /intervention/:id/validate → le CLIENT valide (garde « photos obligatoires »).
 * Le reste (création de devis, MAJ photos/statut par l'artisan) se fait en direct via RLS
 * (l'artisan possède ses lignes). Paiement acompte/solde = branché par métier (phases 1-4)
 * via les RPC wallet déjà durcies.
 */

import { Router, Response } from 'express';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

const router = Router();

const ARTISAN_CODES = ['vitrerie', 'menuiserie', 'plomberie', 'soudure'] as const;

function mapError(msg: string): { code: number; error: string } {
  if (/NOT_CLIENT/.test(msg)) return { code: 403, error: 'Seul le client peut effectuer cette action' };
  if (/NOT_FOUND/.test(msg)) return { code: 404, error: 'Introuvable' };
  if (/PHOTOS_REQUIRED/.test(msg)) return { code: 400, error: 'Photos avant/après obligatoires avant validation' };
  if (/NOT_ACCEPTABLE/.test(msg)) return { code: 409, error: 'Ce devis ne peut plus être accepté' };
  if (/REQUEST_CLOSED/.test(msg)) return { code: 409, error: 'Cette demande n\'accepte plus de devis' };
  if (/CANNOT_QUOTE_OWN_REQUEST/.test(msg)) return { code: 403, error: 'Vous ne pouvez pas répondre à votre propre demande' };
  if (/BAD_SERVICE_TYPE/.test(msg)) return { code: 400, error: 'Métier invalide' };
  if (/TITLE_REQUIRED/.test(msg)) return { code: 400, error: 'Le titre de la demande est obligatoire' };
  if (/QUOTE_INVALID/.test(msg)) return { code: 400, error: 'Devis lié invalide' };
  if (/NOT_COMPLETED/.test(msg)) return { code: 409, error: 'L\'intervention doit être terminée avant de payer le solde' };
  if (/INSUFFICIENT_FUNDS/.test(msg)) return { code: 402, error: 'Solde wallet insuffisant' };
  if (/WALLET_BLOCKED/.test(msg)) return { code: 403, error: 'Wallet bloqué' };
  if (/WALLET_NOT_FOUND/.test(msg)) return { code: 404, error: 'Wallet introuvable' };
  if (/DUPLICATE_PAYMENT/.test(msg)) return { code: 409, error: 'Paiement déjà effectué' };
  return { code: 400, error: msg };
}

/** Métiers artisans réellement exercés par l'utilisateur (via professional_services). */
async function getArtisanTrades(userId: string): Promise<string[]> {
  const { data } = await supabaseAdmin
    .from('professional_services')
    .select('service_types(code)')
    .eq('user_id', userId);
  const codes = (data ?? [])
    .map((r: any) => r?.service_types?.code)
    .filter((c: string) => (ARTISAN_CODES as readonly string[]).includes(c));
  return Array.from(new Set(codes));
}

/** POST /api/v2/artisan/quote/:id/accept — le client accepte le devis. */
router.post('/quote/:id/accept', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin.rpc('accept_artisan_quote_atomic', {
      p_quote_id: req.params.id, p_actor_user_id: req.user!.id,
    });
    if (error) { const m = mapError(error.message); res.status(m.code).json({ success: false, error: m.error }); return; }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) {
    logger.error(`[artisan/accept] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de l\'acceptation' });
  }
});

/** POST /api/v2/artisan/intervention/:id/validate — le client valide (photos obligatoires). */
router.post('/intervention/:id/validate', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin.rpc('validate_artisan_intervention_atomic', {
      p_intervention_id: req.params.id, p_actor_user_id: req.user!.id,
    });
    if (error) { const m = mapError(error.message); res.status(m.code).json({ success: false, error: m.error }); return; }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) {
    logger.error(`[artisan/validate] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la validation' });
  }
});

/** POST /api/v2/artisan/requests — le CLIENT publie une demande de devis. */
router.post('/requests', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const b = req.body ?? {};
    const { data, error } = await supabaseAdmin.rpc('create_artisan_request', {
      p_client_id: req.user!.id,
      p_service_type: String(b.service_type ?? ''),
      p_title: String(b.title ?? ''),
      p_description: b.description ?? null,
      p_photos: Array.isArray(b.photos) ? b.photos : [],
      p_address: b.address ?? null,
      p_city: b.city ?? null,
      p_latitude: b.latitude ?? null,
      p_longitude: b.longitude ?? null,
      p_urgency: b.urgency ?? 'normal',
      p_preferred_date: b.preferred_date ?? null,
    });
    if (error) { const m = mapError(error.message); res.status(m.code).json({ success: false, error: m.error }); return; }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) {
    logger.error(`[artisan/requests:create] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la création de la demande' });
  }
});

/** GET /api/v2/artisan/requests/open — job board filtré sur les métiers de l'artisan connecté. */
router.get('/requests/open', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const trades = await getArtisanTrades(req.user!.id);
    if (trades.length === 0) { res.json({ success: true, requests: [] }); return; }
    const { data, error } = await supabaseAdmin.rpc('list_open_artisan_requests', {
      p_service_types: trades, p_limit: 100,
    });
    if (error) { const m = mapError(error.message); res.status(m.code).json({ success: false, error: m.error }); return; }
    res.json({ success: true, requests: data ?? [] });
  } catch (e: any) {
    logger.error(`[artisan/requests:open] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors du chargement des demandes' });
  }
});

/** POST /api/v2/artisan/requests/:id/quote — l'ARTISAN dépose (ou met à jour) son devis. */
router.post('/requests/:id/quote', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const b = req.body ?? {};
    const { data, error } = await supabaseAdmin.rpc('submit_artisan_quote_for_request', {
      p_request_id: req.params.id,
      p_artisan_id: req.user!.id,
      p_items: Array.isArray(b.items) ? b.items : [],
      p_total_ht: b.total_ht ?? 0,
      p_tax_rate: b.tax_rate ?? 18,
      p_total_ttc: b.total_ttc ?? 0,
      p_photos: Array.isArray(b.photos) ? b.photos : [],
      p_notes: b.notes ?? null,
      p_valid_until: b.valid_until ?? null,
    });
    if (error) { const m = mapError(error.message); res.status(m.code).json({ success: false, error: m.error }); return; }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) {
    logger.error(`[artisan/requests:quote] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors du dépôt du devis' });
  }
});

/** POST /api/v2/artisan/intervention/:id/deposit — le client paie l'acompte (défaut 30%). */
router.post('/intervention/:id/deposit', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const pct = Number(req.body?.deposit_pct);
    const { data, error } = await supabaseAdmin.rpc('pay_artisan_deposit_atomic', {
      p_intervention_id: req.params.id, p_actor_user_id: req.user!.id,
      p_deposit_pct: Number.isFinite(pct) ? pct : 30,
    });
    if (error) { const m = mapError(error.message); res.status(m.code).json({ success: false, error: m.error }); return; }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) {
    logger.error(`[artisan/deposit] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors du paiement de l\'acompte' });
  }
});

/** POST /api/v2/artisan/intervention/:id/balance — le client paie le solde (après validation). */
router.post('/intervention/:id/balance', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin.rpc('pay_artisan_balance_atomic', {
      p_intervention_id: req.params.id, p_actor_user_id: req.user!.id,
    });
    if (error) { const m = mapError(error.message); res.status(m.code).json({ success: false, error: m.error }); return; }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) {
    logger.error(`[artisan/balance] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors du paiement du solde' });
  }
});

export default router;
