/**
 * 🧠 CONTEXTE SYSTÈME — « mémoire » + « observation » partagées par le Copilot PDG et l'auto-réparation.
 *
 *  - getSystemMap()       : carte de TOUTES les interfaces/rôles + fonctionnalités + domaines surveillés
 *                           + services actifs (ce que le système SAIT faire) — la « mémoire ».
 *  - getLiveObservation() : ce qui se passe MAINTENANT — alertes actives, événements récents, incidents
 *                           ouverts, échecs de jobs — l'« observation ».
 *
 * Injecté dans le prompt du Copilot PDG et dans le diagnostic dual-IA pour qu'ils raisonnent avec une
 * vision complète et à jour du système. Bornes strictes (limites) pour maîtriser la taille/coût.
 */

import { supabaseAdmin } from '../config/supabase.js';
import { MONITOR_DOMAINS } from './escrowMonitor.service.js';

// Les grandes interfaces/rôles de l'app (la liste des fonctionnalités fines vient de la DB ci-dessous).
const INTERFACES = [
  'PDG (supervision globale, finance, sécurité)',
  'Agent (enrôlement/activation utilisateurs & vendeurs, KYC, commissions, sous-agents)',
  'Vendeur (boutique, POS, produits, abonnement)',
  'Vendeur digital (produits téléchargeables)',
  'Client (marketplace, wallet, commandes, suivi)',
  'Actionnaire (parts, revenus)',
  'Livreur (courses, gains)',
  'Taxi-moto (courses, suivi temps réel)',
  'Bureau syndicat (membres, véhicules)',
  'Services de proximité (réservations, devis, agenda)',
];

let _mapCache: { at: number; value: string } | null = null;

/** Carte de l'app (mémoire) — mise en cache 5 min (change rarement). */
export async function getSystemMap(): Promise<string> {
  if (_mapCache && Date.now() - _mapCache.at < 5 * 60_000) return _mapCache.value;
  const parts: string[] = [];
  parts.push('INTERFACES / RÔLES DE L\'APPLICATION :\n' + INTERFACES.map((i) => `- ${i}`).join('\n'));
  parts.push('DOMAINES SURVEILLÉS (chacun a des contrôles d\'anomalie) : ' + MONITOR_DOMAINS.map((d) => d.label).join(' · '));
  try {
    const { data: feats } = await supabaseAdmin.from('core_feature_registry').select('feature_key').eq('enabled', true).limit(120);
    if (feats?.length) parts.push('FONCTIONNALITÉS ENREGISTRÉES (core_feature_registry) : ' + feats.map((f: any) => f.feature_key).join(', '));
  } catch { /* best-effort */ }
  try {
    const { data: svc } = await supabaseAdmin.from('service_types').select('name').eq('is_active', true).limit(50);
    if (svc?.length) parts.push('SERVICES DE PROXIMITÉ ACTIFS : ' + svc.map((s: any) => s.name).join(', '));
  } catch { /* best-effort */ }
  const value = parts.join('\n');
  _mapCache = { at: Date.now(), value };
  return value;
}

/** Observation temps réel (ce qui se passe maintenant). Toujours frais (pas de cache). */
export async function getLiveObservation(): Promise<string> {
  const parts: string[] = [];
  try {
    const { data: alerts } = await supabaseAdmin
      .from('system_alerts')
      .select('module, severity, title, metadata')
      .eq('status', 'active').order('created_at', { ascending: false }).limit(20);
    parts.push(alerts?.length
      ? 'ALERTES ACTIVES :\n' + alerts.map((a: any) => `- [${a.severity}] ${a.module}/${a.metadata?.alert_key || ''} : ${a.title}`).join('\n')
      : 'ALERTES ACTIVES : aucune.');
  } catch { /* best-effort */ }
  try {
    const { data: evts } = await supabaseAdmin
      .from('monitoring_events')
      .select('severity, message, service_name')
      .order('created_at', { ascending: false }).limit(8);
    if (evts?.length) parts.push('ÉVÉNEMENTS RÉCENTS :\n' + evts.map((e: any) => `- [${e.severity}] ${e.service_name}: ${e.message}`).join('\n'));
  } catch { /* best-effort */ }
  try {
    const { data: inc } = await supabaseAdmin
      .from('auto_healing_incidents')
      .select('module, alert_key, remediation_kind, final_action, status')
      .not('status', 'in', '(resolved,applied,failed)').order('created_at', { ascending: false }).limit(20);
    if (inc?.length) parts.push('INCIDENTS OUVERTS (auto-réparation) :\n' + inc.map((i: any) => `- ${i.module}/${i.alert_key} [${i.remediation_kind || '?'}] action:${i.final_action || '?'} (${i.status})`).join('\n'));
  } catch { /* best-effort */ }
  try {
    // Backlog d'erreurs FRONTEND (table system_errors, distincte) : crit. vs mineures (images).
    const [crit, minor] = await Promise.all([
      supabaseAdmin.from('system_errors').select('id', { count: 'exact', head: true }).in('severity', ['critique', 'critical']).or('fix_applied.is.null,fix_applied.eq.false'),
      supabaseAdmin.from('system_errors').select('id', { count: 'exact', head: true }).in('severity', ['mineure', 'modérée']).or('fix_applied.is.null,fix_applied.eq.false'),
    ]);
    parts.push(`ERREURS FRONTEND (system_errors) : ${crit.count ?? 0} critiques (à investiguer) · ${minor.count ?? 0} mineures/modérées (nettoyables en 1 clic).`);
  } catch { /* best-effort */ }
  return parts.join('\n\n');
}
