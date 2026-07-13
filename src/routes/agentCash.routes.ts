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
import { createNotification } from '../services/notification.service.js';

const router = Router();

// ── D3 : garde-fous anti-abus (comptages métier, en plus du rate-limit IP générique) ──
// Constantes (valeurs par défaut ; alignées sur l'intention config PDG).
const MAX_PENDING_PER_PAIR = 3;          // demandes 'pending' simultanées par couple agent↔client
const PAIR_COOLDOWN_MS = 2 * 60 * 1000;  // 2 min entre 2 demandes au même client
const MAX_OPS_PER_AGENT_HOUR = 30;       // opérations/heure par agent
const MAX_SMS_PER_PAIR_HOUR = 3;         // SMS (OTP) par couple agent↔client par heure

/** Vérifie les limites d'une NOUVELLE demande de retrait. Retourne un message d'erreur FR ou null. */
async function checkWithdrawalRequestLimits(agentId: string, clientId: string): Promise<string | null> {
  const hourAgo = new Date(Date.now() - 3600 * 1000).toISOString();
  // 1) Demandes pending simultanées pour ce couple.
  const { count: pendingCount } = await supabaseAdmin.from('agent_cash_requests')
    .select('id', { count: 'exact', head: true })
    .eq('agent_id', agentId).eq('client_user_id', clientId).eq('type', 'withdrawal').eq('status', 'pending');
  if ((pendingCount ?? 0) >= MAX_PENDING_PER_PAIR) {
    return `Trop de demandes en attente pour ce client (max ${MAX_PENDING_PER_PAIR}). Attendez qu'elles soient confirmées ou expirées.`;
  }
  // 2) Cooldown entre 2 demandes au même client.
  const { data: last } = await supabaseAdmin.from('agent_cash_requests')
    .select('created_at').eq('agent_id', agentId).eq('client_user_id', clientId).eq('type', 'withdrawal')
    .order('created_at', { ascending: false }).limit(1).maybeSingle();
  if (last && (Date.now() - new Date((last as any).created_at).getTime()) < PAIR_COOLDOWN_MS) {
    return 'Veuillez patienter 2 minutes avant une nouvelle demande à ce client.';
  }
  // 3) Débit d'opérations par agent sur la dernière heure.
  const { count: opsCount } = await supabaseAdmin.from('agent_cash_requests')
    .select('id', { count: 'exact', head: true })
    .eq('agent_id', agentId).eq('type', 'withdrawal').gte('created_at', hourAgo);
  if ((opsCount ?? 0) >= MAX_OPS_PER_AGENT_HOUR) {
    return `Limite horaire atteinte (${MAX_OPS_PER_AGENT_HOUR} opérations/heure). Réessayez plus tard.`;
  }
  return null;
}

/** Limite anti-gaspillage SMS : max N OTP par couple agent↔client par heure. Message FR ou null. */
async function checkSmsLimit(agentId: string, clientId: string): Promise<string | null> {
  const hourAgo = new Date(Date.now() - 3600 * 1000).toISOString();
  const { count } = await supabaseAdmin.from('agent_cash_otp')
    .select('id', { count: 'exact', head: true })
    .eq('agent_id', agentId).eq('client_user_id', clientId).gte('created_at', hourAgo);
  if ((count ?? 0) >= MAX_SMS_PER_PAIR_HOUR) {
    return `Trop de SMS envoyés à ce client (max ${MAX_SMS_PER_PAIR_HOUR}/heure). Réessayez plus tard.`;
  }
  return null;
}

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

// Résolution UNIVERSELLE et STRICTE d'un utilisateur par identifiant : téléphone (RPC stricte)
// OU ID 224. Les DEUX systèmes d'ID affichés aux clients selon l'écran sont couverts :
//   • profiles.public_id  (VARCHAR(8), ex. USR12345 / VND0001)
//   • user_ids.custom_id  ('USR' + 7 chiffres, ex. USR1234567)
// Les IDs sont stockés en MAJUSCULES → on uppercase l'entrée (donc insensible à la casse).
// Anti-ambiguïté : si l'entrée matche des comptes DIFFÉRENTS (ou plusieurs dans une table),
// on REFUSE — jamais de LIMIT 1 silencieux (même philosophie que la résolution téléphone stricte).
async function resolveUserIdByIdentifier(identifier: string): Promise<{ userId: string } | { error: string }> {
  const raw = String(identifier || '').trim();
  if (!raw) return { error: 'ID 224 ou numéro de téléphone requis.' };

  const looksPhone = /^\+?[\d\s-]{6,}$/.test(raw);
  if (!looksPhone) {
    const up = raw.toUpperCase();
    const [pubRes, cusRes] = await Promise.all([
      supabaseAdmin.from('profiles').select('id').eq('public_id', up).limit(2),
      supabaseAdmin.from('user_ids').select('user_id').eq('custom_id', up).limit(2),
    ]);
    const pubRows = (pubRes.data as any[]) || [];
    const cusRows = (cusRes.data as any[]) || [];
    const AMBIGU = 'Cet identifiant correspond à plusieurs comptes — utilisez le numéro de téléphone.';
    // Doublon interne à une table OU les 2 tables pointent des comptes différents → on ne devine pas.
    if (pubRows.length > 1 || cusRows.length > 1) return { error: AMBIGU };
    const pubId = pubRows[0]?.id ?? null;
    const cusId = cusRows[0]?.user_id ?? null;
    if (pubId && cusId && pubId !== cusId) return { error: AMBIGU };
    const uid = pubId ?? cusId;
    if (uid) return { userId: uid as string };
    return { error: 'Aucun compte trouvé avec cet identifiant.' };
  }

  // Téléphone STRICT (comportement inchangé).
  const { data, error } = await supabaseAdmin.rpc('resolve_user_id_by_phone_strict', { p_phone: raw });
  if (error) {
    if (/PHONE_AMBIGUOUS/i.test(error.message)) return { error: 'Numéro ambigu — demandez au client de contacter le support.' };
    return { error: 'Vérification du numéro impossible.' };
  }
  if (!data) return { error: 'Numéro introuvable ou ambigu — vérifiez le numéro ou contactez le support.' };
  return { userId: data as string };
}

// Résout le client (téléphone OU ID 224) et renvoie nom + téléphone (le téléphone sert aux SMS
// OTP/preuve : quand l'agent saisit un ID, on ne connaît pas le numéro sans cette résolution).
async function resolveClient(identifier: string): Promise<{ id: string; name: string; phone: string | null } | { error: string }> {
  const r = await resolveUserIdByIdentifier(identifier);
  if ('error' in r) return { error: r.error };
  const { data: prof } = await supabaseAdmin.from('profiles').select('first_name, last_name, phone').eq('id', r.userId).maybeSingle();
  const name = `${(prof as any)?.first_name || ''} ${(prof as any)?.last_name || ''}`.trim() || 'Client 224';
  return { id: r.userId, name, phone: (prof as any)?.phone || null };
}

// Peut activer un agent cash = PDG (tranché ailleurs) OU agent de GESTION avec la permission.
async function canActivateCashAgents(userId: string): Promise<boolean> {
  const { data } = await supabaseAdmin.from('agents_management')
    .select('id').eq('user_id', userId).eq('can_activate_cash_agents', true).eq('is_active', true).maybeSingle();
  return !!data;
}

// Masque le milieu d'un téléphone pour la préview (garde début + 2 derniers).
function maskPhone(ph?: string | null): string | null {
  const s = String(ph || '').trim();
  if (!s) return null;
  if (s.length <= 4) return s;
  return s.slice(0, 4) + '••••' + s.slice(-2);
}

// Résout une cible par ID 224 (profiles.public_id) OU téléphone (strict) et renvoie un profil
// de PRÉVIEW (nom, rôle, avatar, téléphone masqué) avant confirmation d'activation.
async function resolveTargetProfile(identifier: string): Promise<
  { id: string; name: string; role: string | null; avatar_url: string | null; phone_masked: string | null } | { error: string }
> {
  const r = await resolveUserIdByIdentifier(identifier);
  if ('error' in r) return { error: r.error };
  const { data: prof } = await supabaseAdmin.from('profiles')
    .select('first_name, last_name, full_name, role, avatar_url, phone').eq('id', r.userId).maybeSingle();
  const p = (prof as any) || {};
  const name = (p.full_name || `${p.first_name || ''} ${p.last_name || ''}`).trim() || 'Utilisateur 224';
  return { id: r.userId, name, role: p.role || null, avatar_url: p.avatar_url || null, phone_masked: maskPhone(p.phone) };
}

// Les 2 messages EXACTS d'activation (R2). Envoi push si token FCM, sinon repli SMS.
async function notifyActivation(targetUserId: string, phone: string | null): Promise<void> {
  const title = 'Compte agent cash activé';
  const msg1 = 'Votre compte a été activé pour faire le dépôt et retrait.';
  const msg2 = 'À partir de maintenant, vous pouvez déposer et retirer de l\'argent pour les clients et gagner des commissions sur chaque transaction. 224Solutions vous remercie.';
  try {
    // 1) IN-APP (source de vérité, toujours visible dans la cloche) — les 2 messages R2.
    await createNotification({ userId: targetUserId, title, message: msg1, type: 'agent_cash_activated' });
    await createNotification({ userId: targetUserId, title, message: msg2, type: 'agent_cash_activated' });
    // 2) Push best-effort (si token FCM), sinon repli SMS.
    if (await userHasFcmToken(targetUserId)) {
      await sendPushToUser(targetUserId, { title, message: msg1, data: { type: 'agent_cash_activated' } });
    } else if (phone) {
      await sendSms(phone, `224Solutions : ${msg1}`);
      await sendSms(phone, msg2);
    }
  } catch (e: any) { logger.warn(`[agent-cash] notif activation ignorée: ${e?.message}`); }
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

// « Retrait moi-même » SUPPRIMÉ (agent cash v2) : le wallet EST le capital de l'agent.
// Pour sortir son argent vers Orange Money / banque, l'agent utilise le Retrait STANDARD du wallet.

// ── Préview de la cible (ID 224 ou téléphone) avant activation — R2 ───────────
// Autorité (R1) : PDG OU agent de gestion avec permission can_activate_cash_agents.
router.post('/resolve-target', verifyJWT, authRateLimit, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const actorIsPdg = await isPdg(req.user!.id);
  if (!actorIsPdg && !(await canActivateCashAgents(req.user!.id))) {
    res.status(403).json({ success: false, error: 'Réservé au PDG et aux agents de gestion autorisés.' }); return;
  }
  const r = await resolveTargetProfile(String(req.body?.identifier ?? req.body?.phone ?? ''));
  if ('error' in r) { res.status(409).json({ success: false, error: r.error }); return; }
  res.json({ success: true, data: r });
});

// ── Activer un utilisateur comme agent cash ──────────────────────────────────
// Autorité (R1) : PDG OU agent de GESTION avec permission. AUCUN agent cash n'active
// (parrainage SUPPRIMÉ). Le rôle d'origine de la cible est conservé.
router.post('/activate-user', verifyJWT, authRateLimit, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const actorIsPdg = await isPdg(req.user!.id);
  if (!actorIsPdg && !(await canActivateCashAgents(req.user!.id))) {
    res.status(403).json({ success: false, error: 'Réservé au PDG et aux agents de gestion autorisés.' }); return;
  }
  const target = await resolveTargetProfile(String(req.body?.identifier ?? req.body?.phone ?? ''));
  if ('error' in target) { res.status(409).json({ success: false, error: target.error }); return; }
  const { data, error } = await supabaseAdmin.rpc('activate_cash_agent', {
    p_target_user_id: target.id, p_actor_user_id: req.user!.id, p_actor_is_pdg: actorIsPdg,
  });
  if (error) { const e = mapRpcError(error.message); res.status(e.code).json({ success: false, error: e.error }); return; }
  // R2 : 2 notifications d'activation (push, repli SMS). Non bloquant.
  const { data: prof } = await supabaseAdmin.from('profiles').select('phone').eq('id', target.id).maybeSingle();
  await notifyActivation(target.id, (prof as any)?.phone || null);
  logger.info(`[agent-cash] ${req.user!.id} a activé ${target.id} comme agent cash (pdg=${actorIsPdg})`);
  res.json({ success: true, data: { ...(data as any), name: (data as any)?.name || target.name } });
});

// ── Lookup client (confirmation visuelle avant opération) ────────────────────
router.post('/lookup-client', verifyJWT, authRateLimit, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const agent = await getAgentForUser(req.user!.id);
  if (!agent) { res.status(403).json({ success: false, error: 'Compte agent introuvable' }); return; }
  // Préview COMPLÈTE (nom + avatar + téléphone masqué + rôle) : l'agent voit QUI est le client.
  const r = await resolveTargetProfile(String(req.body?.identifier ?? req.body?.phone ?? ''));
  if ('error' in r) { res.status(409).json({ success: false, error: r.error }); return; }
  res.json({ success: true, data: { name: r.name, avatar_url: r.avatar_url, phone_masked: r.phone_masked, role: r.role } });
});

// ── Dépôt cash ───────────────────────────────────────────────────────────────
router.post('/deposit', verifyJWT, paymentRateLimit, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const agent = await getAgentForUser(req.user!.id);
  if (!agent) { res.status(403).json({ success: false, error: 'Compte agent introuvable' }); return; }
  const amount = Number(req.body?.amount);
  if (!posInt(amount)) { res.status(400).json({ success: false, error: 'Montant invalide (entier positif)' }); return; }
  const client = await resolveClient(String(req.body?.identifier ?? req.body?.phone ?? ''));
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
  const identifier = String(req.body?.identifier ?? req.body?.phone ?? '');
  const amount = Number(req.body?.amount);
  const client = await resolveClient(identifier);
  if ('error' in client) { res.status(409).json({ success: false, error: client.error }); return; }
  // Le SMS OTP part vers le VRAI numéro du client (pas l'entrée : ça peut être un ID 224).
  if (!client.phone) { res.status(409).json({ success: false, error: "Ce client n'a pas de numéro pour recevoir un code OTP." }); return; }

  // D3 : anti-gaspillage SMS (max N OTP par couple agent↔client par heure).
  const smsErr = await checkSmsLimit(agent.id, client.id);
  if (smsErr) { res.status(429).json({ success: false, error: smsErr }); return; }

  const ok = await issueClientOtp(agent.id, client.id, client.phone, posInt(amount) ? amount : null);
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
  const client = await resolveClient(String(req.body?.identifier ?? req.body?.phone ?? ''));
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
  const identifier = String(req.body?.identifier ?? req.body?.phone ?? '');
  const amount = Number(req.body?.amount);
  if (!posInt(amount)) { res.status(400).json({ success: false, error: 'Montant invalide (entier positif)' }); return; }
  const client = await resolveClient(identifier);
  if ('error' in client) { res.status(409).json({ success: false, error: client.error }); return; }

  // D3 : garde-fous anti-abus (pending simultanés / cooldown / débit horaire agent).
  const limitErr = await checkWithdrawalRequestLimits(agent.id, client.id);
  if (limitErr) { res.status(429).json({ success: false, error: limitErr }); return; }

  const key = req.body?.idempotency_key || newKey();
  const fee = await computeWithdrawalFee(amount);
  // Avatar de l'agent (lecture seule du profil) → affiché côté client (« qui me demande de l'argent »).
  const { data: agentProf } = await supabaseAdmin.from('profiles').select('avatar_url').eq('id', agent.user_id).maybeSingle();
  const agentAvatar = (agentProf as any)?.avatar_url || null;
  // Canal AUTO : push si token FCM ; sinon OTP si le client a un numéro ; sinon IN-APP seule.
  const hasFcm = await userHasFcmToken(client.id);
  const channel = hasFcm ? 'push' : (client.phone ? 'otp' : 'inapp');

  const { data: reqRow, error } = await supabaseAdmin.from('agent_cash_requests').insert({
    type: 'withdrawal', agent_id: agent.id, client_user_id: client.id, amount, fees: fee, channel,
    status: 'pending', idempotency_key: key, expires_at: new Date(Date.now() + 3 * 60 * 1000).toISOString(),
  }).select('id').single();
  if (error) { res.status(500).json({ success: false, error: 'Demande impossible' }); return; }
  const requestId = (reqRow as any).id;

  // IN-APP = SOURCE DE VÉRITÉ : créée SYSTÉMATIQUEMENT, AVANT tout canal best-effort, quel que soit le canal.
  await createNotification({
    userId: client.id,
    title: 'Confirmation de retrait',
    message: `L'agent ${agent.name} demande un retrait de ${gnf(amount)} — Frais ${gnf(fee)} — Total débité ${gnf(amount + fee)}. Expire dans 3 minutes.`,
    type: 'agent_cash_withdrawal_request',
    metadata: { link: `/cash-confirm/${requestId}`, action_url: `/cash-confirm/${requestId}`, request_id: requestId, amount, fees: fee, agent_name: agent.name, agent_avatar_url: agentAvatar },
  });

  let clientNotice: string | undefined;
  if (channel === 'push') {
    void sendPushToUser(client.id, {
      title: 'Confirmation de retrait',
      message: `L'agent ${agent.name} demande un retrait de ${gnf(amount)} — Frais ${gnf(fee)} — Total débité ${gnf(amount + fee)}.`,
      actionUrl: `/cash-confirm/${requestId}`,
      data: { type: 'agent_cash_withdrawal_request', request_id: requestId, amount, fees: fee },
    });
  } else if (channel === 'otp' && client.phone) {
    await issueClientOtp(agent.id, client.id, client.phone, amount);   // OTP au VRAI numéro (JAMAIS vide)
  } else {
    // inapp : ni push ni téléphone → l'in-app suffit ; l'agent invite le client à ouvrir son app.
    clientNotice = "Ce client n'a ni notifications push ni numéro de téléphone — demandez-lui d'ouvrir son application 224Solutions (cloche ou wallet) pour confirmer.";
  }
  res.json({ success: true, data: { request_id: requestId, channel, client_name: client.name, amount, fees: fee, agent_name: agent.name, agent_avatar_url: agentAvatar, ...(clientNotice ? { client_notice: clientNotice } : {}) } });
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
    await createNotification({ userId: clientId, title: 'Retrait expiré', message: 'La demande de retrait a expiré (3 min).', type: 'agent_cash_withdrawal_result' });
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
  await createNotification({ userId: clientId, title: 'Retrait confirmé', message: `Votre retrait de ${gnf(r.amount)} a été confirmé.`, type: 'agent_cash_withdrawal_result' });
  res.json({ success: true, data });
});

// ── FLUX 1 : le CLIENT refuse ──
router.post('/withdrawal/reject', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const { error } = await supabaseAdmin.from('agent_cash_requests')
    .update({ status: 'rejected' }).eq('id', String(req.body?.request_id || '')).eq('client_user_id', req.user!.id).eq('status', 'pending');
  if (error) { res.status(400).json({ success: false, error: error.message }); return; }
  await createNotification({ userId: req.user!.id, title: 'Retrait refusé', message: 'Vous avez refusé la demande de retrait.', type: 'agent_cash_withdrawal_result' });
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
  // D3 : anti-gaspillage SMS (max N OTP par couple agent↔client par heure).
  const smsErr = await checkSmsLimit(agent.id, r.client_user_id);
  if (smsErr) { res.status(429).json({ success: false, error: smsErr }); return; }
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

// ── Espace agent (v2) : plancher sur le SOLDE WALLET + stats commissions (plus de float séparé) ──
router.get('/me', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const agent = await getAgentForUser(req.user!.id);
  if (!agent) { res.status(403).json({ success: false, error: 'Compte agent introuvable' }); return; }
  const { data: ledger } = await supabaseAdmin.from('agent_cash_ledger').select('*').eq('agent_id', agent.id).order('created_at', { ascending: false }).limit(50);
  const { data: pending } = await supabaseAdmin.from('agent_commission_pending').select('*').eq('agent_id', agent.id).eq('status', 'pending');
  const { data: payouts } = await supabaseAdmin.from('agent_commission_payout_requests').select('*').eq('agent_id', agent.id).order('created_at', { ascending: false }).limit(20);

  // v2 : le solde wallet de l'agent couvre-t-il le plancher opérationnel (dans SA devise) ?
  const { data: walletOk } = await supabaseAdmin.rpc('agent_cash_wallet_ok', { p_agent_id: agent.id });
  // Stats commissions (jour/mois/total) depuis le ledger (agent_commission_credit), dans la devise de l'agent.
  const { data: commissionStats } = await supabaseAdmin.rpc('agent_cash_commission_stats', { p_agent_id: agent.id });

  // Autorité d'activation (R1) : agent de GESTION autorisé à activer des agents cash ?
  const canActivate = await canActivateCashAgents(req.user!.id);
  const { data: cfg } = await supabaseAdmin.rpc('agent_cash_active_config');

  res.json({ success: true, data: {
    agent, ledger: ledger || [], pending: pending || [], payouts: payouts || [],
    can_activate_cash_agents: canActivate,
    wallet_balance_ok_for_cash: !!(walletOk as any)?.ok,
    wallet_cash_status: walletOk || null,             // { ok, currency, balance, floor, min_gnf, reason? }
    commission_stats: commissionStats || { today: 0, month: 0, total: 0 },
    min_wallet_balance_for_cash_ops: Number((cfg as any)?.min_wallet_balance_for_cash_ops ?? 100000),
  } });
});

// ── Chantier B : historique COMPLET des commissions (dépôts ET retraits), paginé ──
// Chaque dépôt/retrait a SA commission (invariant PDG) → cet historique EST l'historique des
// opérations. Lecture seule, filtré sur l'agent authentifié.
router.get('/me/commissions', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const agent = await getAgentForUser(req.user!.id);
  if (!agent) { res.status(403).json({ success: false, error: 'Compte agent introuvable' }); return; }
  const page = Math.max(1, parseInt(String(req.query.page || '1'), 10) || 1);
  const pageSize = 20;
  const from = (page - 1) * pageSize;

  // Legs de commission (versées + pending) — une par opération.
  const { data: legs } = await supabaseAdmin.from('agent_cash_ledger')
    .select('id, parent_tx_id, operation, amount, status, created_at')
    .eq('agent_id', agent.id).eq('leg', 'agent_commission_credit')
    .order('created_at', { ascending: false })
    .range(from, from + pageSize);   // +1 ligne pour détecter has_more
  const rows = (legs || []) as any[];
  const hasMore = rows.length > pageSize;
  const pageRows = rows.slice(0, pageSize);

  // Montant de l'OPÉRATION source (agent_cash_operations.amount) par parent_tx_id.
  const parentIds = [...new Set(pageRows.map((r) => r.parent_tx_id).filter(Boolean))];
  const opAmount: Record<string, number> = {};
  if (parentIds.length) {
    const { data: ops } = await supabaseAdmin.from('agent_cash_operations')
      .select('parent_tx_id, amount').in('parent_tx_id', parentIds);
    (ops || []).forEach((o: any) => { opAmount[o.parent_tx_id] = Number(o.amount || 0); });
  }

  const items = pageRows.map((r) => ({
    id: r.id,
    created_at: r.created_at,
    type: r.operation,                              // 'deposit' | 'withdrawal'
    operation_amount: opAmount[r.parent_tx_id] ?? 0,
    commission_amount: Number(r.amount || 0),
    reference: r.parent_tx_id,
    status: r.status === 'pending' ? 'pending' : 'credited',
  }));

  const { data: stats } = await supabaseAdmin.rpc('agent_cash_commission_stats', { p_agent_id: agent.id });
  res.json({ success: true, data: { stats: stats || { today: 0, month: 0, total: 0 }, items, page, has_more: hasMore } });
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

// Suspension : PDG OU agent de gestion avec permission (R2), trace de QUI suspend.
router.post('/pdg/suspend/:agentId', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const allowed = (await isPdg(req.user!.id)) || (await canActivateCashAgents(req.user!.id));
  if (!allowed) { res.status(403).json({ success: false, error: 'Réservé au PDG et aux agents de gestion autorisés.' }); return; }
  const reason = String(req.body?.reason || '').trim();
  if (!reason) { res.status(400).json({ success: false, error: 'Motif obligatoire' }); return; }
  const { data, error } = await supabaseAdmin.rpc('agent_cash_set_suspended', { p_agent_id: req.params.agentId, p_suspended: true, p_reason: reason });
  if (error) { res.status(400).json({ success: false, error: error.message }); return; }
  logger.info(`[agent-cash] ${req.user!.id} a suspendu l'agent ${req.params.agentId} (motif: ${reason})`);
  res.json({ success: true, data });
});

router.post('/pdg/unsuspend/:agentId', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const allowed = (await isPdg(req.user!.id)) || (await canActivateCashAgents(req.user!.id));
  if (!allowed) { res.status(403).json({ success: false, error: 'Réservé au PDG et aux agents de gestion autorisés.' }); return; }
  const { data, error } = await supabaseAdmin.rpc('agent_cash_set_suspended', { p_agent_id: req.params.agentId, p_suspended: false, p_reason: null });
  if (error) { res.status(400).json({ success: false, error: error.message }); return; }
  res.json({ success: true, data });
});

// ── Activateurs (PDG) : lister les agents de gestion + accorder/révoquer la permission ─
router.get('/pdg/activators', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  if (!(await isPdg(req.user!.id))) { res.status(403).json({ success: false, error: 'PDG uniquement' }); return; }
  // Agents de GESTION = fiches agents_management NON transformées en agent cash (cash_agent_enabled != true).
  const { data } = await supabaseAdmin.from('agents_management')
    .select('id, name, agent_code, phone, can_activate_cash_agents, is_active')
    .neq('cash_agent_enabled', true)
    .order('name', { ascending: true }).limit(500);
  res.json({ success: true, data: { activators: data || [] } });
});

router.put('/pdg/activators/:agentId', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  if (!(await isPdg(req.user!.id))) { res.status(403).json({ success: false, error: 'PDG uniquement' }); return; }
  const grant = req.body?.can_activate_cash_agents === true;
  const { error } = await supabaseAdmin.from('agents_management')
    .update({ can_activate_cash_agents: grant, updated_at: new Date().toISOString() })
    .eq('id', req.params.agentId);
  if (error) { res.status(400).json({ success: false, error: error.message }); return; }
  logger.info(`[agent-cash] PDG ${req.user!.id} a ${grant ? 'accordé' : 'révoqué'} la permission d'activation à ${req.params.agentId}`);
  res.json({ success: true, data: { can_activate_cash_agents: grant } });
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
