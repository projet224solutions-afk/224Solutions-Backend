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
import { userHasFcmToken, sendPushToUser } from '../services/push.service.js';
import { verifyWalletPin } from '../services/walletPin.service.js';

const router = Router();

// ── Helpers ─────────────────────────────────────────────────────────────────
async function getAgentForUser(userId: string) {
  const { data } = await supabaseAdmin
    .from('agents_management')
    .select('id, user_id, name, agent_code, cash_float_balance, cash_commission_balance, cash_agent_active, cash_agent_enabled, cash_agent_suspended, cash_suspended_reason, can_create_sub_agent')
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
const gnf = (n: any) => `${Number(n || 0).toLocaleString('fr-FR')} GNF`;

// Frais de retrait (MÊME formule que la RPC) — pour affichage/notification (le serveur fait foi).
async function computeWithdrawalFee(amount: number): Promise<number> {
  const { data: cfg } = await supabaseAdmin.rpc('agent_cash_active_config');
  const c = cfg as any;
  if (!c) return 0;
  return Math.min(Math.max(Math.round(amount * c.withdrawal_fee_percent / 100), c.withdrawal_fee_min), c.withdrawal_fee_max);
}

async function clientPhone(userId: string): Promise<string | null> {
  const { data } = await supabaseAdmin.from('profiles').select('phone').eq('id', userId).maybeSingle();
  return (data as any)?.phone || null;
}

// Émet un OTP client (réutilisé par /withdrawal/otp, la bascule AUTO et le fallback manuel).
async function issueClientOtp(agentId: string, clientId: string, phone: string, amount: number | null): Promise<boolean> {
  const otp = String(Math.floor(100000 + Math.random() * 900000));
  const otpHash = crypto.createHash('sha256').update(otp).digest('hex');
  const { error } = await supabaseAdmin.from('agent_cash_otp').insert({
    agent_id: agentId, client_user_id: clientId, otp_hash: otpHash, amount,
    expires_at: new Date(Date.now() + 5 * 60 * 1000).toISOString(),
  });
  if (error) return false;
  await sendSms(phone, `224Solutions : code de retrait ${otp} (valable 5 min). Ne le communiquez qu'à l'agent pour valider votre retrait.`);
  return true;
}

// SMS post-transaction (preuve pour le client à téléphone simple), best-effort.
async function postTxSms(userId: string, text: string): Promise<void> {
  try { const ph = await clientPhone(userId); if (ph) await sendSms(ph, text); } catch { /* non bloquant */ }
}

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

// ── Activer un utilisateur QUELCONQUE comme agent cash ───────────────────────
// Autorité : PDG, OU un agent cash déjà activé & non suspendu (parrainage).
// Le rôle d'origine de la cible est conservé (capacité cash indépendante du rôle).
router.post('/activate-user', verifyJWT, authRateLimit, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const actorIsPdg = await isPdg(req.user!.id);
  if (!actorIsPdg) {
    const actor = await getAgentForUser(req.user!.id);
    if (!actor || !actor.cash_agent_enabled || actor.cash_agent_suspended) {
      res.status(403).json({ success: false, error: 'Réservé au PDG ou à un agent cash actif.' }); return;
    }
  }
  const phone = String(req.body?.phone || '').trim();
  if (!phone) { res.status(400).json({ success: false, error: 'Numéro de téléphone requis.' }); return; }
  const target = await resolveClient(phone);
  if ('error' in target) { res.status(409).json({ success: false, error: target.error }); return; }
  const { data, error } = await supabaseAdmin.rpc('activate_cash_agent', {
    p_target_user_id: target.id, p_actor_user_id: req.user!.id, p_actor_is_pdg: actorIsPdg,
  });
  if (error) {
    const m = (error.message || '').toUpperCase();
    if (m.includes('SPONSORSHIP_DISABLED')) {
      res.status(403).json({ success: false, error: "Le parrainage d'agents est désactivé par la direction.", error_code: 'SPONSORSHIP_DISABLED' }); return;
    }
    if (m.includes('SPONSORSHIP_LIMIT_REACHED')) {
      const { data: cfg } = await supabaseAdmin.rpc('agent_cash_active_config');
      const max = (cfg as any)?.max_sub_agents_per_sponsor;
      res.status(409).json({ success: false, error: `Limite de sous-agents atteinte${max != null ? ` (${max})` : ''} — contactez la direction.`, error_code: 'SPONSORSHIP_LIMIT_REACHED' }); return;
    }
    const e = mapRpcError(error.message); res.status(e.code).json({ success: false, error: e.error }); return;
  }
  logger.info(`[agent-cash] ${req.user!.id} a activé ${target.id} comme agent cash (pdg=${actorIsPdg})`);
  res.json({ success: true, data: { ...(data as any), name: (data as any)?.name || target.name } });
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
  // Notice de dépôt : push simple SANS PIN (recevoir = zéro risque) + SMS de confirmation (preuve).
  void sendPushToUser(client.id, { title: 'Dépôt reçu', message: `${agent.name} vous a déposé ${gnf(amount)}.`, data: { type: 'agent_cash_deposit', amount } });
  void postTxSms(client.id, `224Solutions : depot de ${gnf(amount)} recu via l'agent ${agent.name}.`);
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

  const ok = await issueClientOtp(agent.id, client.id, phone, posInt(amount) ? amount : null);
  if (!ok) { res.status(500).json({ success: false, error: 'Envoi OTP impossible' }); return; }
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
  void postTxSms(client.id, `224Solutions : retrait de ${gnf(amount)} effectue via l'agent ${agent.name}.`);
  res.json({ success: true, data: { ...(data as any), client_name: client.name } });
});

// ── FLUX 1 (défaut) : demande de retrait → PUSH+PIN, ou bascule AUTO OTP si pas de token FCM ──
router.post('/withdrawal/request', verifyJWT, paymentRateLimit, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const agent = await getAgentForUser(req.user!.id);
  if (!agent) { res.status(403).json({ success: false, error: 'Compte agent introuvable' }); return; }
  const phone = String(req.body?.phone || '');
  const amount = Number(req.body?.amount);
  if (!posInt(amount)) { res.status(400).json({ success: false, error: 'Montant invalide (entier positif)' }); return; }
  const client = await resolveClient(phone);
  if ('error' in client) { res.status(409).json({ success: false, error: client.error }); return; }

  const key = req.body?.idempotency_key || newKey();
  const fee = await computeWithdrawalFee(amount);
  const channel = (await userHasFcmToken(client.id)) ? 'push' : 'otp';   // bascule AUTO

  const { data: reqRow, error } = await supabaseAdmin.from('agent_cash_requests').insert({
    type: 'withdrawal', agent_id: agent.id, client_user_id: client.id, amount, fees: fee, channel,
    status: 'pending', idempotency_key: key, expires_at: new Date(Date.now() + 3 * 60 * 1000).toISOString(),
  }).select('id').single();
  if (error) { res.status(500).json({ success: false, error: 'Demande impossible' }); return; }

  if (channel === 'push') {
    void sendPushToUser(client.id, {
      title: 'Confirmation de retrait',
      message: `L'agent ${agent.name} demande un retrait de ${gnf(amount)} — Frais ${gnf(fee)} — Total débité ${gnf(amount + fee)}.`,
      actionUrl: `/cash-confirm/${(reqRow as any).id}`,
      data: { type: 'agent_cash_withdrawal_request', request_id: (reqRow as any).id, amount, fees: fee },
    });
  } else {
    await issueClientOtp(agent.id, client.id, phone, amount);   // fallback auto (téléphone simple)
  }
  res.json({ success: true, data: { request_id: (reqRow as any).id, channel, client_name: client.name, amount, fees: fee } });
});

// ── FLUX 1 : le CLIENT confirme (PIN wallet) → exécute la RPC EXISTANTE ──
router.post('/withdrawal/confirm', verifyJWT, paymentRateLimit, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const clientId = req.user!.id;
  const requestId = String(req.body?.request_id || '');
  const pin = String(req.body?.pin || '');
  await supabaseAdmin.rpc('agent_cash_expire_stale_requests');   // expiration lazy
  const { data: rq } = await supabaseAdmin.from('agent_cash_requests').select('*').eq('id', requestId).eq('client_user_id', clientId).maybeSingle();
  if (!rq) { res.status(404).json({ success: false, error: 'Demande introuvable' }); return; }
  const r = rq as any;
  if (r.status !== 'pending') { res.status(409).json({ success: false, error: 'Demande déjà traitée ou expirée' }); return; }
  if (new Date(r.expires_at).getTime() < Date.now()) {
    await supabaseAdmin.from('agent_cash_requests').update({ status: 'expired' }).eq('id', requestId);
    res.status(409).json({ success: false, error: 'Demande expirée' }); return;
  }

  const pinRes = await verifyWalletPin(clientId, pin);   // service PIN EXISTANT (verrous inclus)
  if (!pinRes.valid) {
    const attempts = r.pin_attempts + 1;
    const canceled = attempts >= 3;
    await supabaseAdmin.from('agent_cash_requests').update({ pin_attempts: attempts, status: canceled ? 'rejected' : 'pending' }).eq('id', requestId);
    res.status(401).json({ success: false, error: canceled ? 'Trop de tentatives — demande annulée.' : (pinRes.error || 'Code PIN invalide'), locked_until: pinRes.lockedUntil }); return;
  }

  const { data, error } = await supabaseAdmin.rpc('agent_cash_withdrawal', {
    p_agent_id: r.agent_id, p_client_user_id: clientId, p_amount: r.amount, p_idempotency_key: r.idempotency_key,
  });
  if (error) { const e = mapRpcError(error.message); res.status(e.code).json({ success: false, error: e.error }); return; }
  await supabaseAdmin.from('agent_cash_requests').update({ status: 'executed', parent_tx_id: (data as any)?.parent_tx_id }).eq('id', requestId);
  void postTxSms(clientId, `224Solutions : retrait de ${gnf(r.amount)} confirme.`);
  res.json({ success: true, data });
});

// ── FLUX 1 : le CLIENT refuse ──
router.post('/withdrawal/reject', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const { error } = await supabaseAdmin.from('agent_cash_requests')
    .update({ status: 'rejected' }).eq('id', String(req.body?.request_id || '')).eq('client_user_id', req.user!.id).eq('status', 'pending');
  if (error) { res.status(400).json({ success: false, error: error.message }); return; }
  res.json({ success: true });
});

// ── Bascule MANUELLE agent → OTP (« le client n'a pas reçu la notification ? ») ──
router.post('/withdrawal/fallback-otp', verifyJWT, authRateLimit, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const agent = await getAgentForUser(req.user!.id);
  if (!agent) { res.status(403).json({ success: false, error: 'Compte agent introuvable' }); return; }
  const { data: rq } = await supabaseAdmin.from('agent_cash_requests').select('*').eq('id', String(req.body?.request_id || '')).eq('agent_id', agent.id).maybeSingle();
  if (!rq || (rq as any).status !== 'pending') { res.status(409).json({ success: false, error: 'Demande non en attente' }); return; }
  const r = rq as any;
  const ph = await clientPhone(r.client_user_id);
  if (!ph) { res.status(409).json({ success: false, error: 'Numéro client indisponible' }); return; }
  await supabaseAdmin.from('agent_cash_requests').update({ channel: 'otp' }).eq('id', r.id);
  const ok = await issueClientOtp(agent.id, r.client_user_id, ph, r.amount);
  if (!ok) { res.status(500).json({ success: false, error: 'Envoi OTP impossible' }); return; }
  res.json({ success: true, data: { sent: true } });
});

// ── FLUX 2 : le CLIENT pré-autorise (montant + PIN) → QR à présenter à l'agent ──
router.post('/withdrawal/client-qr', verifyJWT, paymentRateLimit, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const clientId = req.user!.id;
  const amount = Number(req.body?.amount);
  const pin = String(req.body?.pin || '');
  if (!posInt(amount)) { res.status(400).json({ success: false, error: 'Montant invalide' }); return; }
  const pinRes = await verifyWalletPin(clientId, pin);   // PIN vérifié ICI (avant), l'agent n'en a pas besoin
  if (!pinRes.valid) { res.status(401).json({ success: false, error: pinRes.error || 'Code PIN invalide', locked_until: pinRes.lockedUntil }); return; }

  // Une seule demande QR active à la fois par client (la précédente non expirée bloque).
  await supabaseAdmin.rpc('agent_cash_expire_stale_requests');
  const { data: active } = await supabaseAdmin.from('agent_cash_requests').select('id').eq('client_user_id', clientId).eq('channel', 'qr').eq('status', 'confirmed').limit(1).maybeSingle();
  if (active) { res.status(409).json({ success: false, error: 'Vous avez déjà un QR de retrait actif.' }); return; }

  const reference = crypto.randomBytes(24).toString('base64url');
  const fee = await computeWithdrawalFee(amount);
  const { data: reqRow, error } = await supabaseAdmin.from('agent_cash_requests').insert({
    type: 'withdrawal', agent_id: null, client_user_id: clientId, amount, fees: fee, channel: 'qr',
    status: 'confirmed', reference, idempotency_key: newKey(), expires_at: new Date(Date.now() + 5 * 60 * 1000).toISOString(),
  }).select('id').single();
  if (error) { res.status(500).json({ success: false, error: 'QR indisponible' }); return; }
  res.json({ success: true, data: { request_id: (reqRow as any).id, reference, amount, fees: fee, expires_in: 300 } });
});

// ── FLUX 2 : l'AGENT scanne le QR pré-autorisé → exécution immédiate (PIN déjà validé) ──
router.post('/withdrawal/scan', verifyJWT, paymentRateLimit, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const agent = await getAgentForUser(req.user!.id);
  if (!agent) { res.status(403).json({ success: false, error: 'Compte agent introuvable' }); return; }
  await supabaseAdmin.rpc('agent_cash_expire_stale_requests');
  const { data: rq } = await supabaseAdmin.from('agent_cash_requests').select('*').eq('reference', String(req.body?.reference || '')).maybeSingle();
  if (!rq || (rq as any).status !== 'confirmed') { res.status(409).json({ success: false, error: 'QR invalide ou déjà utilisé' }); return; }
  const r = rq as any;
  if (new Date(r.expires_at).getTime() < Date.now()) {
    await supabaseAdmin.from('agent_cash_requests').update({ status: 'expired' }).eq('id', r.id);
    res.status(409).json({ success: false, error: 'QR expiré' }); return;
  }
  const { data, error } = await supabaseAdmin.rpc('agent_cash_withdrawal', {
    p_agent_id: agent.id, p_client_user_id: r.client_user_id, p_amount: r.amount, p_idempotency_key: r.idempotency_key,
  });
  if (error) { const e = mapRpcError(error.message); res.status(e.code).json({ success: false, error: e.error }); return; }
  await supabaseAdmin.from('agent_cash_requests').update({ status: 'executed', agent_id: agent.id, parent_tx_id: (data as any)?.parent_tx_id }).eq('id', r.id);
  void postTxSms(r.client_user_id, `224Solutions : retrait de ${gnf(r.amount)} effectue.`);
  res.json({ success: true, data: { ...(data as any), amount: r.amount } });
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

  // Capacité de parrainage EFFECTIVE (miroir exact des gardes de activate_cash_agent) :
  // interrupteur global + plafond de sous-agents actifs → le bouton frontend se grise seul.
  const { data: cfg } = await supabaseAdmin.rpc('agent_cash_active_config');
  const sponsorshipOn = (cfg as any)?.allow_agent_sponsorship !== false;
  const maxSub = Number((cfg as any)?.max_sub_agents_per_sponsor ?? 0);
  const { count: subCount } = await supabaseAdmin.from('agents_management')
    .select('id', { count: 'exact', head: true })
    .eq('parent_agent_id', agent.id).eq('cash_agent_enabled', true);
  const subAgents = subCount || 0;
  const remaining = Math.max(0, maxSub - subAgents);
  let reason: string | null = null;
  if (agent.cash_agent_suspended) reason = 'Compte cash suspendu.';
  else if (!agent.cash_agent_enabled) reason = "Compte cash non activé.";
  else if (!sponsorshipOn) reason = "Le parrainage d'agents est désactivé par la direction.";
  else if (remaining <= 0) reason = `Limite de sous-agents atteinte (${maxSub}).`;
  const canRecruit = !reason && !!agent.can_create_sub_agent;
  const recruit = { can_recruit: canRecruit, reason, sub_agents: subAgents, max_sub_agents: maxSub, remaining, sponsorship_enabled: sponsorshipOn };

  res.json({ success: true, data: { agent, ledger: ledger || [], pending: pending || [], payouts: payouts || [], recruit } });
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
  // Répartition des canaux de confirmation (suivi du coût SMS) sur les retraits exécutés 30j.
  const { data: chanRows } = await supabaseAdmin.from('agent_cash_requests')
    .select('channel').eq('type', 'withdrawal').eq('status', 'executed')
    .gte('created_at', new Date(Date.now() - 30 * 24 * 3600 * 1000).toISOString());
  const channels = { push: 0, qr: 0, otp: 0 };
  (chanRows || []).forEach((r: any) => { if (r.channel in channels) (channels as any)[r.channel]++; });
  res.json({ success: true, data: { agents: agents || [], pending: pending || [], payouts: payouts || [], reconciliation: recon, channels } });
});

// Liste des agents cash + recherche (nom / téléphone / code agent). PDG uniquement.
router.get('/pdg/agents', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  if (!(await isPdg(req.user!.id))) { res.status(403).json({ success: false, error: 'PDG uniquement' }); return; }
  // Anti-injection filtre PostgREST : on retire les caractères significatifs de la syntaxe .or().
  const q = String(req.query.q || '').replace(/[,()*%\\:]/g, '').trim().slice(0, 50);
  let query = supabaseAdmin.from('agents_management')
    .select('id, name, agent_code, phone, parent_agent_id, cash_float_balance, cash_commission_balance, cash_agent_enabled, cash_agent_active, cash_agent_suspended, cash_suspended_reason, created_at')
    .or('cash_agent_enabled.eq.true,cash_agent_active.eq.true,cash_float_balance.gt.0')
    .order('created_at', { ascending: false })
    .limit(200);
  if (q) query = query.or(`name.ilike.%${q}%,phone.ilike.%${q}%,agent_code.ilike.%${q}%`);
  const { data, error } = await query;
  if (error) { res.status(500).json({ success: false, error: 'Liste indisponible' }); return; }
  const agents = (data || []) as any[];

  // Enrichissement chaînes de parrainage : nom du parrain + nombre de sous-agents actifs.
  const ids = agents.map((a) => a.id);
  const parentIds = [...new Set(agents.map((a) => a.parent_agent_id).filter(Boolean))];
  const parentNames: Record<string, string> = {};
  if (parentIds.length) {
    const { data: parents } = await supabaseAdmin.from('agents_management').select('id, name').in('id', parentIds);
    (parents || []).forEach((p: any) => { parentNames[p.id] = p.name; });
  }
  const subCounts: Record<string, number> = {};
  if (ids.length) {
    const { data: subs } = await supabaseAdmin.from('agents_management')
      .select('parent_agent_id').in('parent_agent_id', ids).eq('cash_agent_enabled', true);
    (subs || []).forEach((s: any) => { if (s.parent_agent_id) subCounts[s.parent_agent_id] = (subCounts[s.parent_agent_id] || 0) + 1; });
  }
  const enriched = agents.map((a) => ({
    ...a,
    parent_name: a.parent_agent_id ? (parentNames[a.parent_agent_id] || null) : null,
    sub_agents_count: subCounts[a.id] || 0,
  }));
  res.json({ success: true, data: { agents: enriched, truncated: agents.length >= 200 } });
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
