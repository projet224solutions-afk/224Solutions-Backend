/**
 * 🏗️ CONSTRUCTION/BTP — jalons escrow (financer + libérer), RPC atomiques (REVOKE PUBLIC).
 *   POST /api/v2/construction/milestone/:id/fund     → le client finance (débit → escrow).
 *   POST /api/v2/construction/milestone/:id/release  → le client valide → crédite le prestataire.
 */

import { Router, Response } from 'express';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { orderManageRateLimit, adminRateLimit } from '../middlewares/routeRateLimiter.js';

const router = Router();

function mapError(msg: string): { code: number; error: string } {
  if (/NOT_CLIENT/.test(msg)) return { code: 403, error: 'Seul le client peut effectuer cette action' };
  if (/NOT_FOUND/.test(msg)) return { code: 404, error: 'Jalon introuvable' };
  if (/NOT_FUNDED/.test(msg)) return { code: 409, error: 'Le jalon doit être financé avant validation' };
  if (/INSUFFICIENT_FUNDS/.test(msg)) return { code: 402, error: 'Solde wallet insuffisant' };
  if (/WALLET_BLOCKED/.test(msg)) return { code: 403, error: 'Wallet bloqué' };
  if (/BAD_AMOUNT/.test(msg)) return { code: 400, error: 'Montant invalide' };
  return { code: 400, error: msg };
}

router.post('/project/:id/claim', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin.rpc('claim_construction_project', { p_project_id: req.params.id, p_actor_user_id: req.user!.id });
    if (error) { const code = /ALREADY_CLAIMED/.test(error.message) ? 409 : 400; res.status(code).json({ success: false, error: error.message }); return; }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) { logger.error(`[btp/claim] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur' }); }
});

router.post('/milestone/:id/fund', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin.rpc('fund_construction_milestone_atomic', { p_milestone_id: req.params.id, p_actor_user_id: req.user!.id });
    if (error) { const m = mapError(error.message); res.status(m.code).json({ success: false, error: m.error }); return; }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) { logger.error(`[btp/fund] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur financement' }); }
});

router.post('/milestone/:id/release', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin.rpc('release_construction_milestone_atomic', { p_milestone_id: req.params.id, p_actor_user_id: req.user!.id });
    if (error) { const m = mapError(error.message); res.status(m.code).json({ success: false, error: m.error }); return; }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) { logger.error(`[btp/release] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur libération' }); }
});

// ── LITIGES JALON (ÉTAPE 4) ──────────────────────────────────────────────────
// Les RPC open/resolve renvoient {success,error} dans data (pas de RAISE).
const DISPUTE_ERR: Record<string, string> = {
  MILESTONE_NOT_FOUND: 'Jalon introuvable',
  ONLY_FUNDED_DISPUTABLE: 'Un litige ne peut être ouvert que sur un jalon financé',
  NOT_A_PARTY: 'Réservé au client ou au prestataire du chantier',
  REASON_REQUIRED: 'Motif requis (5 caractères min.)',
  DISPUTE_ALREADY_OPEN: 'Un litige est déjà ouvert sur ce jalon',
  NOT_AUTHORIZED: 'Réservé à un administrateur',
  DISPUTE_NOT_FOUND: 'Litige introuvable',
  ALREADY_RESOLVED: 'Litige déjà résolu',
  MILESTONE_NOT_FUNDED: 'Le jalon n\'est plus en séquestre',
  BAD_DECISION: 'Décision invalide',
};

// Le client OU le prestataire ouvre un litige sur un jalon financé.
router.post('/milestone/:id/dispute', verifyJWT, orderManageRateLimit, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const reason = String((req.body || {}).reason || '');
    const { data, error } = await supabaseAdmin.rpc('open_construction_milestone_dispute', {
      p_milestone_id: req.params.id, p_actor_user_id: req.user!.id, p_reason: reason,
    });
    if (error) { res.status(400).json({ success: false, error: error.message }); return; }
    const r = data as any;
    if (!r?.success) { res.status(400).json({ success: false, error: DISPUTE_ERR[r?.error] || r?.error || 'Erreur' }); return; }
    res.json({ success: true, ...r });
  } catch (e: any) { logger.error(`[btp/dispute-open] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur' }); }
});

// Un admin/pdg résout un litige (release → prestataire | refund → client).
router.post('/dispute/:id/resolve', verifyJWT, adminRateLimit, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { decision, note } = req.body || {};
    if (!['release', 'refund'].includes(String(decision))) { res.status(400).json({ success: false, error: 'Décision invalide' }); return; }
    const { data, error } = await supabaseAdmin.rpc('resolve_construction_milestone_dispute', {
      p_dispute_id: req.params.id, p_actor_user_id: req.user!.id, p_decision: decision, p_note: note || null,
    });
    if (error) { res.status(400).json({ success: false, error: error.message }); return; }
    const r = data as any;
    if (!r?.success) { const code = r?.error === 'NOT_AUTHORIZED' ? 403 : 400; res.status(code).json({ success: false, error: DISPUTE_ERR[r?.error] || r?.error || 'Erreur' }); return; }
    res.json({ success: true, ...r });
  } catch (e: any) { logger.error(`[btp/dispute-resolve] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur' }); }
});

// Vue PDG : litiges ouverts (avec montant du jalon + chantier). Réservé admin/pdg/ceo.
router.get('/disputes', verifyJWT, adminRateLimit, async (req: AuthenticatedRequest, res: Response) => {
  try {
    if (!['admin', 'pdg', 'ceo'].includes(req.user!.role)) { res.status(403).json({ success: false, error: 'Accès refusé' }); return; }
    const { data, error } = await supabaseAdmin
      .from('construction_milestone_disputes')
      .select('id, milestone_id, project_id, opener_role, reason, status, created_at, construction_milestones(title, amount, status), construction_projects(name, location)')
      .eq('status', 'open')
      .order('created_at', { ascending: true });
    if (error) { res.status(400).json({ success: false, error: error.message }); return; }
    res.json({ success: true, disputes: data || [] });
  } catch (e: any) { logger.error(`[btp/disputes] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur' }); }
});

export default router;
