/**
 * 🟠 SMS Orange — surveillance du SOLDE PAR PAYS (anti-panne).
 * Pour chaque pays activé (ORANGE_SMS_{ISO}_ENABLED=true) : lit le solde via
 * /sms/admin/v1, l'upsert dans sms_country_balance (lu par l'écran PDG), et lève
 * une alerte system_alerts (dédupliquée) sous le seuil ORANGE_SMS_LOW_BALANCE_THRESHOLD.
 * Un solde à zéro NE bloque PAS : le provider refuse et la passerelle bascule sur Twilio.
 */
import { env } from '../../config/env.js';
import { logger } from '../../config/logger.js';
import { supabaseAdmin } from '../../config/supabase.js';
import { cache } from '../../config/redis.js';
import { orangeEnabledCountries, orangeBalance, orangeGloballyReady } from './orangeSms.js';

const MODULE = 'sms_gateway';

type AlertKind = 'low' | 'depleted' | 'expired' | 'inactive';

/** Lève (ou déduplique) une alerte PDG pour un pays (solde bas/épuisé ou contrat expiré/non actif). */
async function raiseAlert(iso: string, units: number, kind: AlertKind, expiresAt?: string | null): Promise<void> {
  // Clé de dédup par TYPE : une alerte « contrat expiré » ne masque pas une « solde bas » et vice-versa.
  const alertKey = kind === 'expired' ? `orange_sms_expired_${iso}`
    : kind === 'inactive' ? `orange_sms_inactive_${iso}`
    : `orange_sms_low_${iso}`;
  const { data: existing } = await supabaseAdmin
    .from('system_alerts').select('id').eq('module', MODULE).eq('status', 'active')
    .filter('metadata->>alert_key', 'eq', alertKey).maybeSingle();
  if (existing) return; // déjà signalé et non résolu

  const when = expiresAt ? ` (expiré le ${String(expiresAt).slice(0, 10)})` : '';
  const spec: Record<AlertKind, { title: string; message: string; severity: string; fix: string }> = {
    expired: {
      title: `[SMS Orange] CONTRAT EXPIRÉ — ${iso}`,
      message: `Le contrat SMS Orange ${iso} est EXPIRÉ${when}${units > 0 ? ` (${units} unité(s) restent mais INUTILISABLES tant que non renouvelé)` : ''}. Aucun SMS ne part par Orange ; les envois tentent Twilio. RENOUVELEZ le bundle sur developer.orange.com.`,
      severity: 'high',
      fix: `Renouveler / racheter le bundle SMS Orange ${iso} sur https://developer.orange.com (le crédit ne suffit pas : le CONTRAT doit être réactivé).`,
    },
    inactive: {
      title: `[SMS Orange] Contrat NON ACTIF — ${iso}`,
      message: `Le contrat SMS Orange ${iso} n'est pas actif (souscription en attente d'approbation, ou aucun contrat). Aucun SMS ne part par Orange. Vérifiez la souscription sur developer.orange.com.`,
      severity: 'high',
      fix: `Faire approuver / souscrire le contrat SMS Orange ${iso} sur https://developer.orange.com.`,
    },
    depleted: {
      title: `[SMS Orange] Solde ÉPUISÉ — ${iso}`,
      message: `Le crédit SMS Orange ${iso} est épuisé (${units} unité(s)). Les envois basculent sur Twilio. Rechargez le bundle Orange du pays.`,
      severity: 'high',
      fix: `Recharger le bundle SMS Orange du pays ${iso} (paiement en crédit Orange) — voir docs/SMS_ORANGE_CONFIGURATION.md`,
    },
    low: {
      title: `[SMS Orange] Solde bas — ${iso}`,
      message: `Le crédit SMS Orange ${iso} est bas : ${units} unité(s) restantes (seuil ${env.ORANGE_SMS_LOW_BALANCE_THRESHOLD}). Rechargez avant épuisement.`,
      severity: 'medium',
      fix: `Recharger le bundle SMS Orange du pays ${iso} (paiement en crédit Orange) — voir docs/SMS_ORANGE_CONFIGURATION.md`,
    },
  };
  const s = spec[kind];
  await supabaseAdmin.from('system_alerts').insert({
    title: s.title, message: s.message, severity: s.severity, module: MODULE, status: 'active',
    suggested_fix: s.fix,
    metadata: { alert_key: alertKey, country: iso, units, kind, expires_at: expiresAt || null, threshold: env.ORANGE_SMS_LOW_BALANCE_THRESHOLD, source: 'sms.orange-balance-check', created_at: new Date().toISOString() },
  });
  logger.warn(`[SMS/Orange] alerte ${kind} ${iso}: ${units} unité(s)${when}`);
}

/** Résout les alertes non-solde (expiré/inactif) d'un pays quand un contrat redevient actif. */
async function resolveContractAlertsIfActive(iso: string): Promise<void> {
  for (const key of [`orange_sms_expired_${iso}`, `orange_sms_inactive_${iso}`]) {
    await supabaseAdmin.from('system_alerts')
      .update({ status: 'resolved', resolved_at: new Date().toISOString() })
      .eq('module', MODULE).eq('status', 'active')
      .filter('metadata->>alert_key', 'eq', key);
  }
}

/** Résout une alerte solde active si le crédit est repassé au-dessus du seuil. */
async function resolveAlertIfRecovered(iso: string): Promise<void> {
  await supabaseAdmin.from('system_alerts')
    .update({ status: 'resolved', resolved_at: new Date().toISOString() })
    .eq('module', MODULE).eq('status', 'active')
    .filter('metadata->>alert_key', 'eq', `orange_sms_low_${iso}`);
}

/** Passe en revue tous les pays Orange activés et met à jour soldes + alertes + cache. */
export async function checkOrangeBalances(): Promise<{ checked: number; low: number; depleted: number }> {
  if (!orangeGloballyReady()) { logger.info('[SMS/Orange] balance-check ignoré (Orange désactivé)'); return { checked: 0, low: 0, depleted: 0 }; }
  const countries = orangeEnabledCountries();
  const threshold = env.ORANGE_SMS_LOW_BALANCE_THRESHOLD;
  let low = 0, depleted = 0;

  for (const cfg of countries) {
    const bal = await orangeBalance(cfg.iso);
    if (!bal) {
      await supabaseAdmin.from('sms_country_balance').upsert({
        provider: 'orange', country: cfg.iso, units: 0, sender_address: cfg.senderAddress,
        status: 'unavailable', checked_at: new Date().toISOString(),
      }, { onConflict: 'provider,country' });
      logger.warn(`[SMS/Orange] solde indisponible pour ${cfg.iso}`);
      continue;
    }
    // Contrat non ACTIF (expiré / en attente / absent) : des unités peuvent « exister »
    // mais sont INUTILISABLES → on force 0 pour la barrière d'envoi, et on alerte AVEC LA
    // BONNE ACTION (renouveler le contrat ≠ recharger le crédit). C'était le trou : 15 unités
    // « disponibles » sur un contrat EXPIRED faisaient croire à du solde et chaque envoi 403.
    const contractInactive = bal.status !== 'active';
    const usableUnits = contractInactive ? 0 : bal.units;
    const isDepleted = usableUnits <= 0 && !contractInactive;
    const isLow = !isDepleted && !contractInactive && usableUnits < threshold;
    const status = bal.status === 'expired' ? 'expired'
      : bal.status === 'pending' || bal.status === 'none' ? 'inactive'
      : isDepleted ? 'depleted' : isLow ? 'low' : 'ok';

    await supabaseAdmin.from('sms_country_balance').upsert({
      provider: 'orange', country: cfg.iso, units: bal.units, expires_at: bal.expiresAt,
      sender_address: cfg.senderAddress, status, checked_at: new Date().toISOString(),
    }, { onConflict: 'provider,country' });

    // Cache pour la barrière d'envoi (0 si contrat inactif → refus immédiat → bascule).
    await cache.set(`orange:balance:${cfg.iso}`, usableUnits, 6 * 3600);

    if (bal.status === 'expired') { depleted++; await raiseAlert(cfg.iso, bal.units, 'expired', bal.expiresAt); }
    else if (contractInactive) { depleted++; await raiseAlert(cfg.iso, bal.units, 'inactive', bal.expiresAt); }
    else if (isDepleted) { depleted++; await raiseAlert(cfg.iso, bal.units, 'depleted'); }
    else if (isLow) { low++; await raiseAlert(cfg.iso, bal.units, 'low'); }
    else { await resolveAlertIfRecovered(cfg.iso); await resolveContractAlertsIfActive(cfg.iso); }
  }

  logger.info(`[SMS/Orange] balance-check: ${countries.length} pays, ${low} bas, ${depleted} épuisés`);
  return { checked: countries.length, low, depleted };
}
