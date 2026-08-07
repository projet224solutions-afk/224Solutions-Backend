/**
 * 📟 FATOME — ALERTE HORS-BANDE (§4) : SMS au PDG pour les anomalies CRITIQUES.
 * Numéro en CONFIG (pdg_settings.pdg_alert_sms_phone — jamais en dur) ; anti-spam
 * 1 SMS par TYPE d'anomalie et par 6 h (journal append-only fatome_alert_dispatch).
 * Envoi via la passerelle SMS existante (smsGateway : orange → twilio → edge).
 * LIMITE (dite au rapport) : ce chemin passe par le backend — si le backend est MORT
 * (sentinel_dead), l'alerte hors-bande vient de l'ŒIL EXTERNE GitHub Actions (§5),
 * pas d'ici. Aucun secret en base ; jamais bloquant pour la surveillance.
 */
import { logger } from '../config/logger.js';
import { supabaseAdmin } from '../config/supabase.js';
import { sendSms } from './sms.service.js';

const OK_DEDUP_MS = 6 * 3600_000;   // 6 h entre deux SMS réussis d'un même type
const FAIL_DEDUP_MS = 3600_000;     // 1 h avant retry après un échec d'envoi

let phoneCache: { value: string | null; at: number } = { value: null, at: 0 };

async function getPdgAlertPhone(): Promise<string | null> {
  if (Date.now() - phoneCache.at < 60_000) return phoneCache.value;
  try {
    const { data } = await supabaseAdmin
      .from('pdg_settings').select('setting_value')
      .eq('setting_key', 'pdg_alert_sms_phone').maybeSingle();
    const raw: any = data?.setting_value;
    const v = typeof raw === 'string' ? raw : raw?.value;
    phoneCache = { value: typeof v === 'string' && v.trim() ? v.trim() : null, at: Date.now() };
  } catch {
    phoneCache = { value: null, at: Date.now() };
  }
  return phoneCache.value;
}

/** Vide le cache (appelé quand le PDG change le numéro). */
export function invalidatePdgAlertPhoneCache(): void {
  phoneCache = { value: null, at: 0 };
}

export async function dispatchCriticalAnomalySms(): Promise<void> {
  const phone = await getPdgAlertPhone();
  if (!phone) return; // non configuré → aucun SMS (l'in-app reste, le PDG peut configurer dans l'onglet Fatome)

  const { data: crit } = await supabaseAdmin
    .from('fatome_anomalies')
    .select('anomaly_type, ref, detected_at')
    .eq('severity', 'critical').eq('resolved', false)
    .order('detected_at', { ascending: false }).limit(20);
  if (!crit?.length) return;

  const types = [...new Set(crit.map((c: any) => String(c.anomaly_type)))];
  for (const t of types) {
    try {
      const { data: last } = await supabaseAdmin
        .from('fatome_alert_dispatch')
        .select('sent_at, ok').eq('anomaly_type', t)
        .order('sent_at', { ascending: false }).limit(1).maybeSingle();
      if (last?.sent_at) {
        const elapsed = Date.now() - new Date(last.sent_at as string).getTime();
        if ((last.ok && elapsed < OK_DEDUP_MS) || (!last.ok && elapsed < FAIL_DEDUP_MS)) continue;
      }
      const a: any = crit.find((c: any) => c.anomaly_type === t);
      const since = new Date(a.detected_at).toISOString().slice(0, 16).replace('T', ' ');
      const msg = `👻 Fatome CRITIQUE: ${t} — depuis ${since} UTC. Voir Dashboard PDG > Fatome.`;
      const r = await sendSms(phone, msg, undefined, 'notification');
      await supabaseAdmin.from('fatome_alert_dispatch').insert({
        anomaly_type: t, channel: 'sms',
        sent_to_masked: `${phone.slice(0, 5)}****${phone.slice(-2)}`,
        ok: !!r.ok, error: r.ok ? null : String(r.error || 'unknown').slice(0, 300),
      });
      logger.info(`[FatomeAlerts] SMS ${r.ok ? 'OK' : 'ÉCHEC'} (${t}) via ${r.provider || '?'}`);
    } catch (e: any) {
      logger.warn(`[FatomeAlerts] dispatch ${t}: ${e?.message || e}`);
    }
  }
}
