/**
 * 📡 SMS GATEWAY — LA porte de sortie SMS unique de 224Solutions.
 *
 * RÈGLE UNIVERSELLE (décision PDG) : toute authentification par téléphone, pour TOUS les
 * pays, passe par CETTE passerelle. Le fournisseur qui achemine (Orange, Twilio, Edge, ou
 * tout autre ajouté plus tard) est une DÉCISION DE CONFIGURATION, jamais de code :
 *   - l'ORDRE de priorité par pays vit dans la table `sms_country_routing`
 *     ('*' = défaut ; ajouter un pays = INSÉRER UNE LIGNE, zéro redéploiement) ;
 *   - AJOUTER UN FOURNISSEUR = implémenter `SmsProvider` ci-dessous + l'enregistrer dans
 *     `PROVIDERS` + ses variables d'environnement → immédiatement sélectionnable dans les
 *     priorités par pays. Rien d'autre à toucher.
 *
 * Chaque tentative est JOURNALISÉE dans `sms_send_log` (usage, pays, fournisseur, latence,
 * résultat, coût unitaire configuré) → l'écran PDG affiche volume/coût par usage (7/30 j).
 * Échec de TOUS les fournisseurs → alerte `system_alerts` (throttle 1 h / pays).
 */
import { env } from '../../config/env.js';
import { logger } from '../../config/logger.js';
import { supabaseAdmin } from '../../config/supabase.js';
import { orangeSend } from './orangeSms.js';
import { formatPhoneIntl, isoFromE164 } from '../phoneFormat.js';
import { pickOrder as pickOrderPure, maskPhone, hashPhone, DEFAULT_ORDER, type RoutingRow } from './smsRouting.js';

// Ré-export : la logique pure vit dans smsRouting.ts (testable sans env/DB).
export { maskPhone, hashPhone, DEFAULT_ORDER, type RoutingRow };

/** Résultat d'une tentative fournisseur. `skipped` = ce fournisseur ne gère pas ce pays. */
export interface ProviderResult { ok: boolean; error?: string; skipped?: boolean }

/** Interface à implémenter pour AJOUTER un fournisseur (1 fichier + env vars, rien d'autre). */
export interface SmsProvider {
  name: string;
  /** Le fournisseur est-il configuré (env) pour ce pays ? (filtre avant tentative) */
  isConfigured(iso?: string): boolean;
  send(toE164: string, message: string, iso?: string): Promise<ProviderResult>;
}

// ── Fournisseur 1 : ORANGE (multi-pays, contrat local ~150 GNF/SMS en GN) ────────────
const orangeProvider: SmsProvider = {
  name: 'orange',
  isConfigured: () => env.ORANGE_SMS_ENABLED === true || String(env.ORANGE_SMS_ENABLED) === 'true',
  async send(to, message, iso) {
    const r = await orangeSend(to, message, iso);
    return { ok: r.ok, error: r.error, skipped: r.skipped };
  },
};

// ── Fournisseur 2 : TWILIO (international, clés backend) ─────────────────────────────
const twilioProvider: SmsProvider = {
  name: 'twilio',
  isConfigured: () => Boolean(env.TWILIO_ACCOUNT_SID && env.TWILIO_AUTH_TOKEN && (env.TWILIO_MESSAGING_SERVICE_SID || env.TWILIO_PHONE_NUMBER)),
  async send(to, message) {
    const body = new URLSearchParams({ To: to, Body: message });
    if (env.TWILIO_MESSAGING_SERVICE_SID) body.append('MessagingServiceSid', env.TWILIO_MESSAGING_SERVICE_SID);
    else body.append('From', env.TWILIO_PHONE_NUMBER as string);
    const res = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${env.TWILIO_ACCOUNT_SID}/Messages.json`, {
      method: 'POST',
      headers: {
        'Authorization': 'Basic ' + Buffer.from(`${env.TWILIO_ACCOUNT_SID}:${env.TWILIO_AUTH_TOKEN}`).toString('base64'),
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: body.toString(),
    });
    if (!res.ok) {
      let detail = `${res.status}`;
      try { const j: any = await res.json(); detail = j?.message || JSON.stringify(j); } catch { /* ignore */ }
      return { ok: false, error: detail };
    }
    return { ok: true };
  },
};

// ── Fournisseur 3 : EDGE (Edge Function Supabase `send-sms`, secrets Twilio du projet) ──
const edgeProvider: SmsProvider = {
  name: 'edge',
  isConfigured: () => true, // repli de dernier recours — l'edge répond toujours (même pour dire non)
  async send(to, message) {
    const { data, error } = await supabaseAdmin.functions.invoke('send-sms', { body: { to, message } });
    if (error) {
      let detail = error.message;
      try { const ctx = await (error as any).context?.json?.(); if (ctx?.error) detail = ctx.error; } catch { /* ignore */ }
      return { ok: false, error: detail };
    }
    if (data && (data as any).success === false) return { ok: false, error: (data as any).error || 'Échec Edge send-sms' };
    return { ok: true };
  },
};

/** REGISTRE — ajouter un fournisseur = une entrée ici (il devient sélectionnable en config). */
export const PROVIDERS: Record<string, SmsProvider> = {
  orange: orangeProvider,
  twilio: twilioProvider,
  edge: edgeProvider,
};

/** Résolution de l'ordre pour un pays (délègue à la logique pure, registre injecté). */
export function pickOrder(rows: RoutingRow[], iso?: string): { order: string[]; source: string } {
  return pickOrderPure(rows, iso, Object.keys(PROVIDERS));
}

// Cache mémoire du routage (60 s) — l'écran PDG invalide via bustRoutingCache().
let routingCache: { rows: RoutingRow[]; at: number } | null = null;
export function bustRoutingCache(): void { routingCache = null; }

async function loadRouting(): Promise<RoutingRow[]> {
  if (routingCache && Date.now() - routingCache.at < 60_000) return routingCache.rows;
  try {
    const { data } = await supabaseAdmin.from('sms_country_routing')
      .select('country_iso, provider_order, costs, is_active');
    if (data) routingCache = { rows: data as RoutingRow[], at: Date.now() };
    return (data as RoutingRow[]) || [];
  } catch {
    return routingCache?.rows || [];
  }
}

// Alerte « aucun fournisseur » — 1/h par pays, jamais bloquant.
const lastAlertAt = new Map<string, number>();
async function alertAllProvidersFailed(iso: string, usage: string, lastError: string): Promise<void> {
  const key = iso || '??';
  const now = Date.now();
  if (now - (lastAlertAt.get(key) || 0) < 3600_000) return;
  lastAlertAt.set(key, now);
  try {
    await supabaseAdmin.from('system_alerts').insert({
      title: `SMS : aucun fournisseur n'a pu livrer (${key})`,
      message: `Tous les fournisseurs configurés ont échoué pour le pays ${key} (usage: ${usage}). Dernière erreur : ${lastError}. Vérifier crédits/config (écran Passerelle SMS).`,
      severity: 'high',
      module: 'sms_gateway',
      status: 'active',
      metadata: { country: key, usage },
    } as never);
  } catch { /* l'alerte ne casse jamais l'envoi */ }
}

/**
 * ENVOI — cascade selon l'ordre configuré du pays, journalisation de chaque tentative.
 * `usage` catégorise le coût (signup | reset | agent_cash | test | campaign | notification | other).
 */
export async function gatewaySend(
  to: string,
  message: string,
  countryCode?: string,
  usage: string = 'other',
): Promise<{ ok: boolean; error?: string; provider?: string }> {
  if (!to || !message) return { ok: false, error: 'Destinataire ou message manquant' };
  const formatted = formatPhoneIntl(to, countryCode);
  const iso = (countryCode && countryCode.length >= 2 ? countryCode.toUpperCase() : isoFromE164(formatted)) || undefined;

  const rows = await loadRouting();
  const { order } = pickOrder(rows, iso);
  const costs: Record<string, number> = (rows.find((r) => r.country_iso === (iso || ''))?.costs
    || rows.find((r) => r.country_iso === '*')?.costs || {}) as Record<string, number>;

  let lastError = 'Aucun fournisseur configuré pour ce pays';
  for (const name of order) {
    const provider = PROVIDERS[name];
    if (!provider.isConfigured(iso)) continue;
    const started = Date.now();
    let result: ProviderResult;
    try {
      result = await provider.send(formatted, message, iso);
    } catch (err: any) {
      result = { ok: false, error: err?.message || 'exception' };
    }
    const latency = Date.now() - started;
    if (result.skipped) continue; // ce fournisseur ne gère pas ce pays → pas de log ni d'échec

    // Journal (non bloquant) — coût uniquement si l'envoi a réussi.
    supabaseAdmin.from('sms_send_log').insert({
      usage_type: usage,
      country_iso: iso || null,
      provider: name,
      to_masked: maskPhone(formatted),
      to_hash: hashPhone(formatted),
      success: result.ok,
      error: result.ok ? null : (result.error || '').slice(0, 300),
      latency_ms: latency,
      cost: result.ok && costs[name] != null ? costs[name] : null,
    } as never).then(({ error }) => { if (error) logger.warn(`[smsGateway] log: ${error.message}`); });

    if (result.ok) return { ok: true, provider: name };
    lastError = result.error || lastError;
    logger.warn(`[smsGateway] ${name} échec ${maskPhone(formatted)} (${iso || '??'}): ${lastError} → fournisseur suivant`);
  }

  await alertAllProvidersFailed(iso || '', usage, lastError);
  return { ok: false, error: lastError };
}

/** Nombre de demandes récentes pour un numéro/usage (rate-limit 3 / 15 min / numéro, multi-instance). */
export async function recentSendCount(e164: string, usage: string, windowMinutes = 15): Promise<number> {
  try {
    const { count } = await supabaseAdmin.from('sms_send_log')
      .select('id', { count: 'exact', head: true })
      .eq('to_hash', hashPhone(e164))
      .eq('usage_type', usage)
      .gte('created_at', new Date(Date.now() - windowMinutes * 60_000).toISOString());
    return count || 0;
  } catch {
    return 0; // fail-open : le rate-limit ne doit jamais bloquer sur une panne de comptage
  }
}
