/**
 * 💵 AGENT CASH — dépôt/retrait cash, activation float, commissions, config & supervision PDG.
 * Auth : verifyJWT. L'agent est résolu par req.user.id (jamais un agent_id fourni par le client).
 * Identité client : resolve_user_id_by_phone_strict UNIQUEMENT (jamais de LIMIT 1 silencieux).
 * Toute la logique argent est dans les RPC atomiques (une transaction par opération).
 */
import { Router, Request, Response } from 'express';
import crypto from 'crypto';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { authRateLimit, paymentRateLimit } from '../middlewares/routeRateLimiter.js';
import { sendSms } from '../services/sms.service.js';

const router = Router();

// ── Helpers ─────────────────────────────────────────────────────────────────
async function getAgentForUser(userId: string) {
  const { data } = await supabaseAdmin
    .from('agents_management')
    .select('id, user_id, name, cash_float_balance, cash_commission_balance, cash_agent_active, cash_agent_suspended, cash_suspended_reason')
    .eq('user_id', userId)
    .maybeSingle();
  return data as any;
}

async function isPdg(userId: string): Promise<boolean> {
  const { data } = await supabaseAdmin.from('pdg_management').select('id').eq('user_id', userId).eq('is_active', true).maybeSingle();
  if (data) return true;
  const { data: prof } = await supabaseAdmin.from('profiles').select('role').eq('id', userId).maybeSingle();
  return ['pdg', 'admin', 'ceo'].includes(((prof as any)?.role || '').toLowerCase());
}

// Résout le client par téléphone (STRICT) et renvoie son nom pour confirmation visuelle.
async function resolveClient(phone: string): Promise<{ id: string; name: string } | { error: string }> {
  const { data, error } = await supabaseAdmin.rpc('resolve_user_id_by_phone_strict', { p_phone: phone });
  if (error) {
    if (/PHONE_AMBIGUOUS/i.test(error.message)) return { error: 'Numéro ambigu — demandez au client de contacter le support.' };
    return { error: 'Vérification du numéro impossible.' };
  }
  if (!data) return { error: 'Numéro introuvable ou ambigu — vérifiez le numéro ou contactez le support.' };
  const { data: prof } = await supabaseAdmin.from('profiles').select('first_name, last_name').eq('id', data).maybeSingle();
  const name = `${(prof as any)?.first_name || ''} ${(prof as any)?.last_name || ''}`.trim() || 'Client 224';
  return { id: data as string, name };
}

// Mapping des codes d'erreur SQL → messages FR + HTTP.
function mapRpcError(msg: string): { code: number; error: string } {
  const m = (msg || '').toUpperCase();
  if (m.includes('FLOAT_INSUFFISANT')) return { code: 409, error: 'Float insuffisant — rechargez votre float pour continuer.' };
  if (m.includes('SOLDE_INSUFFISANT')) return { code: 409, error: 'Solde client insuffisant pour ce retrait (montant + frais).' };
  if (m.includes('PDG_INSUFFISANT')) return { code: 409, error: 'Trésorerie insuffisante — commission mise en attente.' };
  if (m.includes('AGENT_INACTIF')) return { code: 403, error: 'Agent cash inactif ou suspendu.' };
  if (m.includes('COMMISSION_INSUFFISANTE')) return { code: 409, error: 'Solde de commissions insuffisant.' };
  if (m.includes('PHONE_AMBIGUOUS')) return { code: 409, error: 'Numéro ambigu — demandez au client de contacter le support.' };
  if (m.includes('MONTANT_INVALIDE')) return { code: 400, error: 'Montant invalide.' };
  if (m.includes('FORBIDDEN')) return { code: 403, error: 'Action réservée au PDG.' };
  return { code: 400, error: msg || 'Opération refusée.' };
}

const newKey = () => crypto.randomUUID();
const posInt = (v: any) => Number.isFinite(Number(v)) && Number(v) > 0 && Number.isInteger(Number(v));

// ── Config ────────────────────────────────────────────────────────────────
router.get('/config', verifyJWT, async (_req: AuthenticatedRequest, res: Response): Promise<void> => {
  const { data, error } = await supabaseAdmin.rpc('agent_cash_active_config');
  if (error) { res.status(500).json({ success: false, error: 'Config indisponible' }); return; }
  res.json({ success: true, data });
});

router.put('/config', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  if (!(await isPdg(req.user!.id))) { res.status(403).json({ success: false, error: 'PDG uniquement' }); return; }
  const { data, error } = await supabaseAdmin.rpc('agent_cash_config_update', { p_changes: req.body || {} });
  if (error) {
    const msg = /ck_agent_cash_share_100/i.test(error.message) ? 'Part agent + part PDG doit égaler 100 %.' : error.message;
    res.status(400).json({ success: false, error: msg }); return;
  }
  res.json({ success: true, data });
});

// ── Activation float ────────────────────────────────────────────────────────
router.post('/activate', verifyJWT, paymentRateLimit, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const agent = await getAgentForUser(req.user!.id);
  if (!agent) { res.status(403).json({ success: false, error: 'Compte agent introuvable' }); return; }
  const amount = Number(req.body?.amount);
  if (!posInt(amount)) { res.status(400).json({ success: false, error: 'Montant invalide' }); return; }
  const { data, error } = await supabaseAdmin.rpc('agent_activate_cash', { p_agent_id: agent.id, p_topup_amount: amount, p_idempotency_key: req.body?.idempotency_key || newKey() });
  if (error) { const e = mapRpcError(error.message); res.status(e.code).json({ success: false, error: e.error }); return; }
  res.json({ success: true, data });
});

// ── Lookup client (confirmation visuelle avant opération) ────────────────────
router.post('/lookup-client', verifyJWT, authRateLimit, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const agent = await getAgentForUser(req.user!.id);
  if (!agent) { res.status(403).json({ success: false, error: 'Compte agent introuvable' }); return; }
  const r = await resolveClient(String(req.body?.phone || ''));
  if ('error' in r) { res.status(409).json({ success: false, error: r.error }); return; }
  res.json({ success: true, data: { name: r.name } });
});

// ── Dépôt cash ───────────────────────────────────────────────────────────────
router.post('/deposit', verifyJWT, paymentRateLimit, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const agent = await getAgentForUser(req.user!.id);
  if (!agent) { res.status(403).json({ success: false, error: 'Compte agent introuvable' }); return; }
  const amount = Number(req.body?.amount);
  if (!posInt(amount)) { res.status(400).json({ success: false, error: 'Montant invalide (entier positif)' }); return; }
  const client = await resolveClient(String(req.body?.phone || ''));
  if ('error' in client) { res.status(409).json({ success: false, error: client.error }); return; }

  const { data, error } = await supabaseAdmin.rpc('agent_cash_deposit', {
    p_agent_id: agent.id, p_client_user_id: client.id, p_amount: amount, p_idempotency_key: req.body?.idempotency_key || newKey(),
  });
  if (error) { const e = mapRpcError(error.message); logger.warn(`[agent-cash/deposit] ${error.message}`); res.status(e.code).json({ success: false, error: e.error }); return; }
  res.json({ success: true, data: { ...(data as any), client_name: client.name } });
});

// ── OTP retrait (client possiblement hors ligne) ─────────────────────────────
router.post('/withdrawal/otp', verifyJWT, authRateLimit, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const agent = await getAgentForUser(req.user!.id);
  if (!agent) { res.status(403).json({ success: false, error: 'Compte agent introuvable' }); return; }
  const phone = String(req.body?.phone || '');
  const amount = Number(req.body?.amount);
  const client = await resolveClient(phone);
  if ('error' in client) { res.status(409).json({ success: false, error: client.error }); return; }

  const otp = String(Math.floor(100000 + Math.random() * 900000));
  const otpHash = crypto.createHash('sha256').update(otp).digest('hex');
  const { error } = await supabaseAdmin.from('agent_cash_otp').insert({
    agent_id: agent.id, client_user_id: client.id, otp_hash: otpHash, amount: posInt(amount) ? amount : null,
    expires_at: new Date(Date.now() + 5 * 60 * 1000).toISOString(),
  });
  if (error) { res.status(500).json({ success: false, error: 'Envoi OTP impossible' }); return; }
  await sendSms(phone, `224Solutions : code de retrait ${otp} (valable 5 min). Ne le communiquez qu'à l'agent pour valider votre retrait.`);
  res.json({ success: true, data: { sent: true, client_name: client.name } });
});

// ── Retrait cash (OTP client requis) ─────────────────────────────────────────
router.post('/withdrawal', verifyJWT, paymentRateLimit, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const agent = await getAgentForUser(req.user!.id);
  if (!agent) { res.status(403).json({ success: false, error: 'Compte agent introuvable' }); return; }
  const amount = Number(req.body?.amount);
  const otp = String(req.body?.otp || '');
  if (!posInt(amount)) { res.status(400).json({ success: false, error: 'Montant invalide (entier positif)' }); return; }
  const client = await resolveClient(String(req.body?.phone || ''));
  if ('error' in client) { res.status(409).json({ success: false, error: client.error }); return; }

  // Vérif OTP : dernier OTP non consommé, non expiré, < 3 tentatives, hash concordant.
  const { data: otpRow } = await supabaseAdmin.from('agent_cash_otp')
    .select('id, otp_hash, attempts, consumed, expires_at')
    .eq('agent_id', agent.id).eq('client_user_id', client.id).eq('consumed', false)
    .order('created_at', { ascending: false }).limit(1).maybeSingle();
  if (!otpRow) { res.status(409).json({ success: false, error: 'Aucun code actif — renvoyez un code.' }); return; }
  if (new Date((otpRow as any).expires_at).getTime() < Date.now()) { res.status(409).json({ success: false, error: 'Code expiré — renvoyez un code.' }); return; }
  if ((otpRow as any).attempts >= 3) { res.status(429).json({ success: false, error: 'Trop de tentatives — renvoyez un code.' }); return; }
  const okOtp = crypto.createHash('sha256').update(otp).digest('hex') === (otpRow as any).otp_hash;
  if (!okOtp) {
    await supabaseAdmin.from('agent_cash_otp').update({ attempts: (otpRow as any).attempts + 1 }).eq('id', (otpRow as any).id);
    res.status(401).json({ success: false, error: 'Code incorrect.' }); return;
  }
  await supabaseAdmin.from('agent_cash_otp').update({ consumed: true }).eq('id', (otpRow as any).id);

  const { data, error } = await supabaseAdmin.rpc('agent_cash_withdrawal', {
    p_agent_id: agent.id, p_client_user_id: client.id, p_amount: amount, p_idempotency_key: req.body?.idempotency_key || newKey(),
  });
  if (error) { const e = mapRpcError(error.message); logger.warn(`[agent-cash/withdrawal] ${error.message}`); res.status(e.code).json({ success: false, error: e.error }); return; }
  res.json({ success: true, data: { ...(data as any), client_name: client.name } });
});

// ── Retrait des commissions agent (4 canaux) ─────────────────────────────────
router.post('/commission/withdraw', verifyJWT, paymentRateLimit, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const agent = await getAgentForUser(req.user!.id);
  if (!agent) { res.status(403).json({ success: false, error: 'Compte agent introuvable' }); return; }
  const amount = Number(req.body?.amount);
  const method = String(req.body?.method || '');
  if (!posInt(amount)) { res.status(400).json({ success: false, error: 'Montant invalide' }); return; }
  if (!['orange_money', 'bank', 'to_personal_wallet', 'to_float'].includes(method)) { res.status(400).json({ success: false, error: 'Canal invalide' }); return; }
  const { data, error } = await supabaseAdmin.rpc('agent_commission_withdrawal_request', {
    p_agent_id: agent.id, p_amount: amount, p_method: method, p_destination: req.body?.destination || {}, p_idempotency_key: req.body?.idempotency_key || newKey(),
  });
  if (error) { const e = mapRpcError(error.message); res.status(e.code).json({ success: false, error: e.error }); return; }
  res.json({ success: true, data });
});

// ── Espace agent : mes soldes + historique ledger ────────────────────────────
router.get('/me', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const agent = await getAgentForUser(req.user!.id);
  if (!agent) { res.status(403).json({ success: false, error: 'Compte agent introuvable' }); return; }
  const { data: ledger } = await supabaseAdmin.from('agent_cash_ledger').select('*').eq('agent_id', agent.id).order('created_at', { ascending: false }).limit(50);
  const { data: pending } = await supabaseAdmin.from('agent_commission_pending').select('*').eq('agent_id', agent.id).eq('status', 'pending');
  const { data: payouts } = await supabaseAdmin.from('agent_commission_payout_requests').select('*').eq('agent_id', agent.id).order('created_at', { ascending: false }).limit(20);
  res.json({ success: true, data: { agent, ledger: ledger || [], pending: pending || [], payouts: payouts || [] } });
});

// ── SUPERVISION PDG ──────────────────────────────────────────────────────────
router.get('/pdg/overview', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  if (!(await isPdg(req.user!.id))) { res.status(403).json({ success: false, error: 'PDG uniquement' }); return; }
  const { data: agents } = await supabaseAdmin.from('agents_management')
    .select('id, name, agent_code, cash_float_balance, cash_commission_balance, cash_agent_active, cash_agent_suspended, cash_suspended_reason')
    .or('cash_agent_active.eq.true,cash_float_balance.gt.0');
  const { data: pending } = await supabaseAdmin.from('agent_commission_pending').select('*').eq('status', 'pending').order('created_at', { ascending: false });
  const { data: payouts } = await supabaseAdmin.from('agent_commission_payout_requests').select('*').eq('status', 'pending_pdg').order('created_at', { ascending: false });
  const { data: recon } = await supabaseAdmin.rpc('agent_cash_reconciliation_check');
  res.json({ success: true, data: { agents: agents || [], pending: pending || [], payouts: payouts || [], reconciliation: recon } });
});

router.post('/pdg/suspend/:agentId', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  if (!(await isPdg(req.user!.id))) { res.status(403).json({ success: false, error: 'PDG uniquement' }); return; }
  const reason = String(req.body?.reason || '').trim();
  if (!reason) { res.status(400).json({ success: false, error: 'Motif obligatoire' }); return; }
  const { data, error } = await supabaseAdmin.rpc('agent_cash_set_suspended', { p_agent_id: req.params.agentId, p_suspended: true, p_reason: reason });
  if (error) { res.status(400).json({ success: false, error: error.message }); return; }
  res.json({ success: true, data });
});

router.post('/pdg/unsuspend/:agentId', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  if (!(await isPdg(req.user!.id))) { res.status(403).json({ success: false, error: 'PDG uniquement' }); return; }
  const { data, error } = await supabaseAdmin.rpc('agent_cash_set_suspended', { p_agent_id: req.params.agentId, p_suspended: false, p_reason: null });
  if (error) { res.status(400).json({ success: false, error: error.message }); return; }
  res.json({ success: true, data });
});

router.post('/pdg/pending/:id/:action', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  if (!(await isPdg(req.user!.id))) { res.status(403).json({ success: false, error: 'PDG uniquement' }); return; }
  const action = req.params.action === 'confiscate' ? 'confiscate' : 'release';
  const { data, error } = await supabaseAdmin.rpc('agent_cash_release_pending', { p_pending_id: req.params.id, p_action: action });
  if (error) { const e = mapRpcError(error.message); res.status(e.code).json({ success: false, error: e.error }); return; }
  res.json({ success: true, data });
});

router.post('/pdg/payout/:id/:action', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  if (!(await isPdg(req.user!.id))) { res.status(403).json({ success: false, error: 'PDG uniquement' }); return; }
  const action = req.params.action === 'reject' ? 'reject' : 'approve_paid';
  const { data, error } = await supabaseAdmin.rpc('agent_commission_payout_execute', { p_request_id: req.params.id, p_action: action });
  if (error) { res.status(400).json({ success: false, error: error.message }); return; }
  res.json({ success: true, data });
});

export default router;
