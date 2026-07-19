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

export default router;
