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

/** Lève (ou déduplique) une alerte PDG pour un pays sous le seuil / épuisé. */
async function raiseAlert(iso: string, units: number, depleted: boolean): Promise<void> {
  const alertKey = `orange_sms_low_${iso}`;
  const { data: existing } = await supabaseAdmin
    .from('system_alerts').select('id').eq('module', MODULE).eq('status', 'active')
    .filter('metadata->>alert_key', 'eq', alertKey).maybeSingle();
  if (existing) return; // déjà signalé et non résolu

  await supabaseAdmin.from('system_alerts').insert({
    title: `[SMS Orange] Solde ${depleted ? 'ÉPUISÉ' : 'bas'} — ${iso}`,
    message: depleted
      ? `Le crédit SMS Orange ${iso} est épuisé (${units} unité(s)). Les envois basculent sur Twilio. Rechargez le bundle Orange du pays.`
      : `Le crédit SMS Orange ${iso} est bas : ${units} unité(s) restantes (seuil ${env.ORANGE_SMS_LOW_BALANCE_THRESHOLD}). Rechargez avant épuisement.`,
    severity: depleted ? 'high' : 'medium',
    module: MODULE,
    status: 'active',
    suggested_fix: `Recharger le bundle SMS Orange du pays ${iso} (paiement en crédit Orange) — voir docs/SMS_ORANGE_CONFIGURATION.md`,
    metadata: { alert_key: alertKey, country: iso, units, depleted, threshold: env.ORANGE_SMS_LOW_BALANCE_THRESHOLD, source: 'sms.orange-balance-check', created_at: new Date().toISOString() },
  });
  logger.warn(`[SMS/Orange] alerte solde ${depleted ? 'épuisé' : 'bas'} ${iso}: ${units}`);
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
    const isDepleted = bal.units <= 0;
    const isLow = !isDepleted && bal.units < threshold;
    const status = isDepleted ? 'depleted' : isLow ? 'low' : 'ok';

    await supabaseAdmin.from('sms_country_balance').upsert({
      provider: 'orange', country: cfg.iso, units: bal.units, expires_at: bal.expiresAt,
      sender_address: cfg.senderAddress, status, checked_at: new Date().toISOString(),
    }, { onConflict: 'provider,country' });

    // Cache pour la barrière d'envoi (refus immédiat si épuisé → bascule).
    await cache.set(`orange:balance:${cfg.iso}`, bal.units, 6 * 3600);

    if (isDepleted) { depleted++; await raiseAlert(cfg.iso, bal.units, true); }
    else if (isLow) { low++; await raiseAlert(cfg.iso, bal.units, false); }
    else { await resolveAlertIfRecovered(cfg.iso); }
  }

  logger.info(`[SMS/Orange] balance-check: ${countries.length} pays, ${low} bas, ${depleted} épuisés`);
  return { checked: countries.length, low, depleted };
}
