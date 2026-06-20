/**
 * SIGNALEMENT ABUSE (legal, human-in-the-loop).
 *
 * Quand une IP est bannie definitivement (recidive), on PREPARE un signalement :
 *  - resolution du contact abuse du reseau via RDAP (rdap.org, public, sans cle) ;
 *  - creation d'une alerte PDG (table system_alerts, module 'abuse_report') contenant
 *    le rapport pret a l'emploi + le contact abuse.
 *
 * IMPORTANT : on N'ENVOIE PAS automatiquement d'email a l'abuse contact. L'« IP
 * attaquante » peut etre une machine piratee d'un innocent -> un envoi automatique
 * pourrait harceler une victime. Le PDG valide et envoie manuellement. C'est la
 * pratique legale et responsable.
 */

import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

const RDAP_TIMEOUT_MS = 5000;

interface AbuseContact {
  email: string | null;
  network: string | null;
  org: string | null;
}

/** Resout le contact abuse d'une IP via RDAP. Best-effort (jamais bloquant). */
async function resolveAbuseContact(ip: string): Promise<AbuseContact> {
  const result: AbuseContact = { email: null, network: null, org: null };
  try {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), RDAP_TIMEOUT_MS);
    const resp = await fetch(`https://rdap.org/ip/${encodeURIComponent(ip)}`, {
      signal: ctrl.signal,
      headers: { Accept: 'application/rdap+json' },
    });
    clearTimeout(t);
    if (!resp.ok) return result;
    const data: any = await resp.json();
    result.network = data?.name || data?.handle || null;

    const getVcardField = (entity: any, fieldName: string): string | null => {
      const vcard = entity?.vcardArray?.[1];
      if (!Array.isArray(vcard)) return null;
      const f = vcard.find((x: any) => Array.isArray(x) && x[0] === fieldName);
      return f && typeof f[3] === 'string' ? f[3] : null;
    };

    const scan = (entities: any[]): void => {
      for (const e of entities || []) {
        const roles: string[] = e?.roles || [];
        if (roles.includes('abuse') && !result.email) {
          result.email = getVcardField(e, 'email');
        }
        if ((roles.includes('registrant') || roles.includes('administrative')) && !result.org) {
          result.org = getVcardField(e, 'fn');
        }
        if (Array.isArray(e?.entities)) scan(e.entities);
      }
    };
    scan(Array.isArray(data?.entities) ? data.entities : []);
  } catch {
    /* RDAP indisponible -> on renvoie ce qu'on a (souvent vide) */
  }
  return result;
}

function buildReportText(ip: string, reason: string, contact: AbuseContact): string {
  return [
    `Abuse report - malicious activity from ${ip}`,
    ``,
    `Network: ${contact.network || 'unknown'}${contact.org ? ` (${contact.org})` : ''}`,
    `Abuse contact: ${contact.email || 'not found via RDAP'}`,
    `Timestamp (UTC): ${new Date().toISOString()}`,
    ``,
    `Our automated defense detected and blocked REPEATED attack activity originating`,
    `from this IP address. Details: ${reason}`,
    ``,
    `Action taken on our side: the IP has been permanently blocked.`,
    `We kindly ask you to investigate the source (it may be a compromised host on`,
    `your network) and take appropriate remediation.`,
  ].join('\n');
}

/**
 * Prepare un signalement abuse pour une IP (RDAP + alerte PDG a valider).
 * Best-effort, jamais bloquant pour la riposte. Dedup par IP.
 */
export async function reportAbuse(ip: string, reason: string): Promise<void> {
  try {
    const alertKey = `abuse:${ip}`;
    const { data: existing } = await supabaseAdmin
      .from('system_alerts')
      .select('id')
      .eq('module', 'abuse_report')
      .eq('status', 'active')
      .filter('metadata->>alert_key', 'eq', alertKey)
      .maybeSingle();
    if (existing) return; // signalement deja en attente pour cette IP

    const contact = await resolveAbuseContact(ip);
    const reportText = buildReportText(ip, reason, contact);

    await supabaseAdmin.from('system_alerts').insert({
      title: `[abuse_report] IP hostile ${ip}`,
      message: contact.email
        ? `Signalement pret - contact abuse: ${contact.email} (${contact.network || 'reseau inconnu'}). A valider avant envoi.`
        : `Signalement pret - contact abuse introuvable via RDAP. Reseau: ${contact.network || 'inconnu'}.`,
      severity: 'high',
      module: 'abuse_report',
      status: 'active',
      suggested_fix: reportText,
      metadata: {
        alert_key: alertKey,
        ip,
        abuse_email: contact.email,
        network: contact.network,
        org: contact.org,
        source: 'auto_riposte',
        created_at: new Date().toISOString(),
      },
    });
    logger.warn(`[abuseReport] signalement prepare pour ${ip} (contact: ${contact.email || 'introuvable'})`);
  } catch (e) {
    logger.warn('[abuseReport] echec preparation signalement', e as any);
  }
}
