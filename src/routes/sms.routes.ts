/**
 * 📱 SMS — supervision PDG de la passerelle (état Orange par pays + soldes).
 * Auth : verifyJWT + PDG/admin. Contrat API : ok()/fail(). Aucun secret exposé.
 */
import { Router, Response } from 'express';
import { supabaseAdmin } from '../config/supabase.js';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { ok, fail } from '../utils/apiResponse.js';
import { env } from '../config/env.js';
import { orangeEnabledCountries, orangeGloballyReady, countryConfig } from '../services/sms/orangeSms.js';
import { sendSms } from '../services/sms.service.js';
import { PROVIDERS, bustRoutingCache } from '../services/sms/smsGateway.js';
import { z } from 'zod';

const router = Router();

async function isPdg(userId: string): Promise<boolean> {
  const { data } = await supabaseAdmin.from('pdg_management').select('id').eq('user_id', userId).eq('is_active', true).maybeSingle();
  if (data) return true;
  const { data: prof } = await supabaseAdmin.from('profiles').select('role').eq('id', userId).maybeSingle();
  return ['pdg', 'admin', 'ceo'].includes(((prof as any)?.role || '').toLowerCase());
}

/**
 * État de la passerelle SMS pour l'écran PDG :
 *  - Orange globalement activé + seuil d'alerte
 *  - pays activés (avec sender, SANS aucun secret)
 *  - dernier solde connu par pays (table sms_country_balance)
 */
router.get('/orange/status', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  if (!(await isPdg(req.user!.id))) { fail(res, 403, 'Réservé au PDG', 'FORBIDDEN'); return; }

  const enabled = orangeEnabledCountries().map((c) => ({ country: c.iso, sender_address: c.senderAddress, sender_name: c.senderName }));
  const { data: balances } = await supabaseAdmin
    .from('sms_country_balance')
    .select('country, units, expires_at, status, checked_at, sender_address')
    .eq('provider', 'orange')
    .order('country');

  ok(res, {
    orange_enabled: orangeGloballyReady(),
    low_balance_threshold: env.ORANGE_SMS_LOW_BALANCE_THRESHOLD,
    enabled_countries: enabled,
    balances: balances || [],
  });
});

/** Diagnostic d'un pays : configuré/activé/sender — SANS aucun secret. */
router.get('/orange/country/:iso', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  if (!(await isPdg(req.user!.id))) { fail(res, 403, 'Réservé au PDG', 'FORBIDDEN'); return; }
  const cfg = countryConfig(String(req.params.iso));
  if (!cfg) { fail(res, 400, 'Code pays ISO-2 invalide', 'BAD_ISO'); return; }
  ok(res, { country: cfg.iso, enabled: cfg.enabled, configured: Boolean(cfg.senderAddress), sender_name: cfg.senderName });
});

/**
 * Envoi d'un SMS de TEST (PDG uniquement) — permet de valider la passerelle SEUL,
 * dès qu'un pack Orange/Twilio est provisionné, sans attendre un vrai flux d'inscription.
 * Passe par la cascade sendSms (Orange → Twilio → Edge) et remonte le message RÉEL du
 * fournisseur en cas d'échec (crédit épuisé, numéro non vérifié, from invalide…).
 */
const TestSmsSchema = z.object({
  phone: z.string().trim().min(6, 'Numéro trop court').max(20),
  country: z.string().trim().length(2).optional(),  // ISO-2 pour router le bon fournisseur
});

/**
 * ROUTAGE PAR PAYS (règle universelle) — le PDG voit et modifie, pays par pays, quel
 * fournisseur est utilisé et dans quel ordre. Ajouter un pays = une ligne, zéro code.
 */
router.get('/routing', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  if (!(await isPdg(req.user!.id))) { fail(res, 403, 'Réservé au PDG', 'FORBIDDEN'); return; }
  const { data, error } = await supabaseAdmin.from('sms_country_routing')
    .select('country_iso, provider_order, costs, is_active, note, updated_at')
    .order('country_iso');
  if (error) { fail(res, 500, error.message, 'DB_ERROR'); return; }
  // Fournisseurs disponibles (registre) + configurés (env) — le PDG sait ce qu'il peut choisir.
  const providers = Object.values(PROVIDERS).map((p) => ({ name: p.name, configured: p.isConfigured() }));
  ok(res, { rows: data || [], providers });
});

const RoutingSchema = z.object({
  provider_order: z.array(z.string().min(2).max(30)).min(1).max(10),
  costs: z.record(z.string(), z.number().min(0)).optional(),
  is_active: z.boolean().optional(),
  note: z.string().max(300).nullish(),
});

router.put('/routing/:iso', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  if (!(await isPdg(req.user!.id))) { fail(res, 403, 'Réservé au PDG', 'FORBIDDEN'); return; }
  const iso = String(req.params.iso || '').toUpperCase();
  if (iso !== '*' && !/^[A-Z]{2}$/.test(iso)) { fail(res, 400, 'Code pays ISO-2 (ou *) requis', 'BAD_ISO'); return; }
  const parsed = RoutingSchema.safeParse(req.body);
  if (!parsed.success) { fail(res, 400, parsed.error.issues[0]?.message || 'Données invalides', 'BAD_BODY'); return; }
  // Seuls des fournisseurs CONNUS du registre sont acceptés (une faute de frappe ne casse rien).
  const unknown = parsed.data.provider_order.filter((n) => !PROVIDERS[n]);
  if (unknown.length > 0) {
    fail(res, 400, `Fournisseur(s) inconnu(s) : ${unknown.join(', ')}. Disponibles : ${Object.keys(PROVIDERS).join(', ')}`, 'UNKNOWN_PROVIDER');
    return;
  }
  const { error } = await supabaseAdmin.from('sms_country_routing').upsert({
    country_iso: iso,
    provider_order: parsed.data.provider_order,
    ...(parsed.data.costs ? { costs: parsed.data.costs } : {}),
    ...(parsed.data.is_active !== undefined ? { is_active: parsed.data.is_active } : {}),
    ...(parsed.data.note !== undefined ? { note: parsed.data.note } : {}),
    updated_at: new Date().toISOString(),
    updated_by: req.user!.id,
  }, { onConflict: 'country_iso' });
  if (error) { fail(res, 500, error.message, 'DB_ERROR'); return; }
  bustRoutingCache(); // la PROCHAINE demande suit le nouvel ordre, sans redéploiement
  ok(res, { updated: iso });
});

/**
 * STATS OTP/SMS par usage (7 ou 30 j) — volume, succès, coût par fournisseur et par usage.
 * C'est la base de la négociation Orange au volume.
 */
router.get('/otp-stats', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  if (!(await isPdg(req.user!.id))) { fail(res, 403, 'Réservé au PDG', 'FORBIDDEN'); return; }
  const days = Number(req.query.days) === 30 ? 30 : 7;
  const since = new Date(Date.now() - days * 24 * 3600_000).toISOString();
  const { data, error } = await supabaseAdmin.from('sms_send_log')
    .select('usage_type, provider, country_iso, success, cost')
    .gte('created_at', since)
    .limit(20000);
  if (error) { fail(res, 500, error.message, 'DB_ERROR'); return; }
  const agg = new Map<string, { usage: string; provider: string; sent: number; delivered: number; cost: number }>();
  for (const r of (data || []) as any[]) {
    const key = `${r.usage_type}|${r.provider}`;
    const row = agg.get(key) || { usage: r.usage_type, provider: r.provider, sent: 0, delivered: 0, cost: 0 };
    row.sent += 1;
    if (r.success) { row.delivered += 1; row.cost += Number(r.cost || 0); }
    agg.set(key, row);
  }
  ok(res, { days, rows: Array.from(agg.values()).sort((a, b) => b.sent - a.sent) });
});

router.post('/test', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  if (!(await isPdg(req.user!.id))) { fail(res, 403, 'Réservé au PDG', 'FORBIDDEN'); return; }
  const parsed = TestSmsSchema.safeParse(req.body);
  if (!parsed.success) { fail(res, 400, parsed.error.issues[0]?.message || 'Numéro de test invalide', 'BAD_PHONE'); return; }
  const { phone, country } = parsed.data;
  const stamp = new Date().toISOString().slice(11, 19);
  const message = `224Solutions - Test passerelle SMS (${stamp}). Si vous recevez ce message, l'envoi fonctionne pour ce numero.`;
  const r = await sendSms(phone, message, country ? country.toUpperCase() : undefined, 'test');
  if (!r.ok) { fail(res, 502, r.error || "Échec de l'envoi", 'SMS_SEND_FAILED'); return; }
  ok(res, { sent: true });
});

export default router;
