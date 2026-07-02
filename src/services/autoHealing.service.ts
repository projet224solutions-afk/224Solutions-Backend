/**
 * 🛠️ AUTO-RÉPARATION SUPERVISÉE (dual-IA) — FONDATION.
 *
 * Pipeline : un incident détecté par la surveillance (system_alerts) →
 *   1) OpenAI diagnostique + propose une remédiation (parmi un REGISTRE borné).
 *   2) Claude VÉRIFIE la proposition ; s'il rejette, il ré-analyse et corrige.
 *   3) On classe la remédiation : `auto_safe` (idempotent) ou `needs_human` (argent/sensible),
 *      et on ENREGISTRE la chaîne dans auto_healing_incidents.
 *
 * FONDATION : aucune exécution automatique ici (corrections seulement PROPOSÉES).
 * L'exécution sera branchée domaine par domaine après validation du diagnostic.
 * Tout est best-effort : ne fait jamais échouer la surveillance.
 */

import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { jobQueue } from '../jobs/jobQueue.js';
import { getLiveObservation } from './systemContext.service.js';

type RemediationKind = 'auto_safe' | 'needs_human';
interface Remediation { action: string; label: string; kind: RemediationKind; }

// Registre des remédiations connues, par clé d'anomalie (alert_key). Les actions `auto_safe`
// sont IDEMPOTENTES (relancer un job/scrape) ; les `needs_human` touchent l'argent → escalade.
const REMEDIATION_REGISTRY: Record<string, Remediation> = {
  // ── auto_safe (idempotent, ré-exécutable sans risque) ──
  held_overdue:            { action: 'trigger_escrow_autorelease', label: 'Relancer le job de libération des escrows échus', kind: 'auto_safe' },
  stale_rates:             { action: 'rescrape_bcrg',              label: 'Re-scraper les taux BCRG (taux périmés > 24h)',     kind: 'auto_safe' },
  sub_expired_active_vendor:  { action: 'run_subscription_expire', label: "Relancer l'expiration des abonnements vendeur",    kind: 'auto_safe' },
  sub_expired_active_driver:  { action: 'run_subscription_expire', label: "Relancer l'expiration des abonnements chauffeur",  kind: 'auto_safe' },
  sub_expired_active_service: { action: 'run_subscription_expire', label: "Relancer l'expiration des abonnements service",    kind: 'auto_safe' },
  pos_stock_pending:       { action: 'run_pos_reconciliation',     label: 'Relancer la réconciliation de stock POS',          kind: 'auto_safe' },
  frontend_errors_backlog: { action: 'cleanup_frontend_errors',    label: 'Nettoyer les erreurs frontend mineures (images) en attente', kind: 'auto_safe' },

  // ── needs_human (argent / sécurité / intégrité : jamais auto) ──
  untraced_increase:        { action: 'freeze_and_investigate', label: 'Geler le wallet et investiguer (argent hors circuit)', kind: 'needs_human' },
  wallet_negative_balance:  { action: 'escalate_finance',       label: 'Corriger un solde wallet négatif (sur-débit)',         kind: 'needs_human' },
  wallet_duplicate_deposit: { action: 'escalate_finance',       label: 'Examiner un dépôt dupliqué (double-crédit)',           kind: 'needs_human' },
  disputes_refund_unfunded: { action: 'escalate_finance',       label: 'Litige remboursé mais escrow non remboursé',          kind: 'needs_human' },
  disputes_release_unreleased:{ action: 'escalate_finance',     label: 'Litige libéré mais escrow non libéré',                kind: 'needs_human' },
  net_mismatch:             { action: 'escalate_finance',       label: 'Incohérence net = montant − frais (ledger)',          kind: 'needs_human' },
  currency_mismatch:        { action: 'escalate_finance',       label: 'Devise de libération ≠ devise escrow',                kind: 'needs_human' },
  pos_negative_stock:       { action: 'escalate_inventory',     label: 'Stock négatif (décrément concurrent incohérent)',     kind: 'needs_human' },
  frontend_service_role_key:{ action: 'escalate_security',      label: 'CRITIQUE : clé service_role exposée dans le bundle',   kind: 'needs_human' },
  frontend_secret_exposed:  { action: 'escalate_security',      label: 'Secret exposé dans le bundle public',                  kind: 'needs_human' },
};
const DEFAULT_REMEDIATION: Remediation = { action: 'investigate', label: 'Investigation manuelle requise', kind: 'needs_human' };

function remediationFor(alertKey: string): Remediation {
  return REMEDIATION_REGISTRY[alertKey] || DEFAULT_REMEDIATION;
}

// ── Fournisseurs IA (best-effort, renvoient un objet JSON ou null) ──────────
async function openaiJSON(system: string, user: string): Promise<any | null> {
  const key = process.env.OPENAI_API_KEY;
  if (!key) return null;
  try {
    const r = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: 'gpt-4o-mini', temperature: 0.2, max_tokens: 400,
        response_format: { type: 'json_object' },
        messages: [{ role: 'system', content: system }, { role: 'user', content: user }],
      }),
    });
    if (!r.ok) { logger.warn(`[autoHealing] openai ${r.status}`); return null; }
    const d: any = await r.json();
    const txt = d.choices?.[0]?.message?.content || '';
    return safeParse(txt);
  } catch (e: any) { logger.warn(`[autoHealing] openai err ${e?.message}`); return null; }
}

async function claudeJSON(system: string, user: string): Promise<any | null> {
  const key = process.env.ANTHROPIC_API_KEY;
  if (!key) return null;
  try {
    const r = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'x-api-key': key, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
      body: JSON.stringify({
        model: 'claude-sonnet-4-6', max_tokens: 500, system,
        messages: [{ role: 'user', content: user }],
      }),
    });
    if (!r.ok) { logger.warn(`[autoHealing] claude ${r.status}`); return null; }
    const d: any = await r.json();
    const txt = (Array.isArray(d.content) ? d.content.find((c: any) => c.type === 'text')?.text : '') || '';
    return safeParse(txt);
  } catch (e: any) { logger.warn(`[autoHealing] claude err ${e?.message}`); return null; }
}

function safeParse(txt: string): any | null {
  try {
    const s = String(txt);
    const a = s.indexOf('{'); const b = s.lastIndexOf('}');
    if (a < 0 || b < 0) return null;
    return JSON.parse(s.slice(a, b + 1));
  } catch { return null; }
}

// ── Pipeline de diagnostic d'un incident ────────────────────────────────────
interface IncidentRow {
  id: string; module: string | null; alert_key: string | null; severity: string | null;
  title: string | null; detail: string | null; context: any;
}

async function runDualAIDiagnosis(inc: IncidentRow, observation = ''): Promise<void> {
  const reg = remediationFor(inc.alert_key || '');
  const allowed = [reg.action, 'investigate', 'escalate_finance', 'escalate_security'];
  const suggested = inc.context?.suggested_fix || '';
  const incidentBrief =
    (observation ? `OBSERVATION TEMPS RÉEL DU SYSTÈME (contexte global) :\n${observation}\n\n` : '') +
    `INCIDENT À TRAITER\nmodule: ${inc.module}\nclé: ${inc.alert_key}\nsévérité: ${inc.severity}\ntitre: ${inc.title}\ndétail: ${inc.detail}\n` +
    `correctif suggéré (base de connaissance): ${suggested}\n` +
    `action candidate du registre: ${reg.action} (${reg.label}) [${reg.kind}]\n` +
    `actions autorisées: ${allowed.join(', ')}`;

  const update: Record<string, any> = { updated_at: new Date().toISOString() };

  // 1) OpenAI : diagnostic + proposition
  const oa = await openaiJSON(
    "Tu es un ingénieur SRE de la plateforme 224Solutions (fintech). On te donne un incident détecté par la surveillance. Donne un diagnostic COURT de la cause probable et choisis UNE action de remédiation parmi la liste autorisée (ne touche JAMAIS à l'argent sans escalade humaine). Réponds en JSON : {\"diagnosis\":\"...\",\"recommended_action\":\"<id parmi autorisées>\",\"auto_safe\":true|false,\"rationale\":\"...\"}.",
    incidentBrief,
  );
  if (oa) {
    update.openai_diagnosis = String(oa.diagnosis || '').slice(0, 1500);
    update.openai_action = allowed.includes(oa.recommended_action) ? oa.recommended_action : reg.action;
    update.openai_rationale = String(oa.rationale || '').slice(0, 1000);
  }

  // 2) Claude : vérification / correction de la proposition d'OpenAI
  let finalAction = (update.openai_action as string) || reg.action;
  if (oa) {
    const cl = await claudeJSON(
      "Tu es l'ingénieur SRE SENIOR qui RELIT la proposition d'un collègue avant application sur une plateforme fintech. Vérifie qu'elle est correcte, SÛRE et ATOMIQUE. Toute action touchant l'argent (remboursement, libération, solde) doit rester 'needs_human'. Si la proposition est bonne, approuve-la ; sinon corrige-la. Réponds en JSON : {\"verdict\":\"approved|revised|rejected\",\"analysis\":\"...\",\"final_action\":\"<id parmi autorisées>\",\"auto_safe\":true|false}.",
      `${incidentBrief}\n\nPROPOSITION DU COLLÈGUE (OpenAI):\ndiagnostic: ${update.openai_diagnosis}\naction: ${update.openai_action}\njustification: ${update.openai_rationale}`,
    );
    if (cl) {
      update.claude_verdict = ['approved', 'revised', 'rejected'].includes(cl.verdict) ? cl.verdict : 'revised';
      update.claude_analysis = String(cl.analysis || '').slice(0, 1500);
      update.claude_action = allowed.includes(cl.final_action) ? cl.final_action : finalAction;
      finalAction = update.claude_action;
    }
  }

  // 3) Décision finale + classification. La SÛRETÉ vient du REGISTRE (source de vérité),
  //    jamais du seul jugement de l'IA : une action ne peut être auto_safe que si le
  //    registre la déclare auto_safe ET qu'elle correspond à l'action candidate.
  const isRegistrySafe = reg.kind === 'auto_safe' && finalAction === reg.action;
  update.final_action = finalAction;
  update.remediation_label = reg.label;
  update.remediation_kind = isRegistrySafe ? 'auto_safe' : 'needs_human';
  update.auto_apply_eligible = isRegistrySafe;
  // FONDATION : on ne fait que proposer/escalader (aucune exécution).
  update.status = isRegistrySafe ? 'proposed' : 'escalated';

  const { error } = await supabaseAdmin.from('auto_healing_incidents').update(update).eq('id', inc.id);
  if (error) logger.warn(`[autoHealing] update incident ${inc.id} failed: ${error.message}`);
}

// ── Ingestion : transforme les system_alerts actives en incidents (dédup) ───
async function ingestActiveAlerts(): Promise<string[]> {
  const created: string[] = [];
  const { data: alerts, error } = await supabaseAdmin
    .from('system_alerts')
    .select('id, title, message, severity, module, suggested_fix, metadata, created_at')
    .eq('status', 'active')
    .order('created_at', { ascending: false })
    .limit(100);
  if (error) { logger.warn(`[autoHealing] read alerts failed: ${error.message}`); return created; }

  // AUTO-RÉSOLUTION : un incident issu d'une alerte qui n'est PLUS active → l'anomalie est corrigée
  // (manuellement ou par remédiation) → on ferme l'incident, il ne traîne pas dans le tableau PDG.
  const activeKeys = new Set((alerts || [])
    .map((a: any) => `${String(a.module || '')}:${String(a.metadata?.alert_key || '')}`)
    .filter((k) => k !== ':'));
  try {
    const { data: openInc } = await supabaseAdmin
      .from('auto_healing_incidents')
      .select('id, incident_key')
      .eq('source', 'system_alert')
      .not('status', 'in', '(resolved,applied,failed)');
    const toClose = (openInc || []).filter((i: any) => !activeKeys.has(i.incident_key)).map((i: any) => i.id);
    if (toClose.length) {
      await supabaseAdmin.from('auto_healing_incidents')
        .update({ status: 'resolved', updated_at: new Date().toISOString() }).in('id', toClose);
      logger.info(`[autoHealing] auto-résolus (alerte disparue): ${toClose.length}`);
    }
  } catch (e: any) { logger.warn(`[autoHealing] auto-resolve failed: ${e?.message}`); }

  for (const a of alerts || []) {
    const alertKey = String((a as any).metadata?.alert_key || '');
    const module = String((a as any).module || '');
    if (!alertKey || !module) continue;
    const incidentKey = `${module}:${alertKey}`;

    // Un incident OUVERT existe déjà pour cette clé ? (index partiel uniq_auto_healing_open)
    const { data: existing } = await supabaseAdmin
      .from('auto_healing_incidents')
      .select('id').eq('incident_key', incidentKey)
      .not('status', 'in', '(resolved,applied,failed)').maybeSingle();
    if (existing) continue;

    const { data: ins, error: insErr } = await supabaseAdmin.from('auto_healing_incidents').insert({
      incident_key: incidentKey, source: 'system_alert', module, alert_key: alertKey,
      severity: (a as any).severity || 'medium',
      title: (a as any).title || `[${module}] ${alertKey}`,
      detail: (a as any).message || '',
      context: { suggested_fix: (a as any).suggested_fix || '', alert_id: (a as any).id, metadata: (a as any).metadata || {} },
      status: 'detected',
    }).select('id').maybeSingle();
    if (insErr) { logger.warn(`[autoHealing] insert incident failed (${incidentKey}): ${insErr.message}`); continue; }
    if (ins?.id) created.push(ins.id);
  }
  return created;
}

// Ingestion du BACKLOG d'erreurs FRONTEND (table system_errors, distincte de system_alerts) : crée un
// incident si trop d'erreurs mineures/modérées en attente (majorité = chargement d'images). Auto-résolu
// quand le backlog repasse sous le seuil. Ne compte PAS les 'critique' (réservées à l'investigation).
async function ingestFrontendErrorsBacklog(): Promise<void> {
  const incidentKey = 'frontend_errors:backlog';
  const THRESHOLD = 200;
  try {
    const { count } = await supabaseAdmin.from('system_errors')
      .select('id', { count: 'exact', head: true })
      .in('severity', ['mineure', 'modérée'])
      .or('fix_applied.is.null,fix_applied.eq.false');
    const { data: existing } = await supabaseAdmin.from('auto_healing_incidents')
      .select('id').eq('incident_key', incidentKey).not('status', 'in', '(resolved,applied,failed)').maybeSingle();

    if (!count || count < THRESHOLD) {
      if (existing) await supabaseAdmin.from('auto_healing_incidents')
        .update({ status: 'resolved', updated_at: new Date().toISOString() }).eq('id', existing.id);
      return;
    }
    if (existing) return; // incident déjà ouvert
    await supabaseAdmin.from('auto_healing_incidents').insert({
      incident_key: incidentKey, source: 'system_errors', module: 'frontend_errors', alert_key: 'frontend_errors_backlog',
      severity: 'medium', title: `${count} erreurs frontend mineures en attente`,
      detail: "Majoritairement des échecs de chargement d'images (frontend_resource). Nettoyage sûr disponible (sans toucher aux erreurs critiques).",
      context: { pending: count, suggested_fix: 'Marquer résolues les erreurs mineures/modérées en attente (table system_errors).' },
      status: 'detected',
    });
  } catch (e: any) { logger.warn(`[autoHealing] frontend backlog ingest: ${e?.message}`); }
}

// ── Orchestrateur : ingère puis diagnostique les incidents non encore diagnostiqués ──
export async function scanAndDiagnose(limit = 20): Promise<{ ingested: number; diagnosed: number }> {
  const created = await ingestActiveAlerts();
  await ingestFrontendErrorsBacklog();

  const { data: pending } = await supabaseAdmin
    .from('auto_healing_incidents')
    .select('id, module, alert_key, severity, title, detail, context')
    .eq('status', 'detected')
    .order('created_at', { ascending: true })
    .limit(limit);

  // Observation live calculée UNE fois pour tout le lot (mémoire/observation partagée).
  const observation = (pending && pending.length) ? await getLiveObservation() : '';
  let diagnosed = 0;
  for (const inc of (pending || []) as IncidentRow[]) {
    await runDualAIDiagnosis(inc, observation);
    diagnosed++;
  }
  logger.info(`[autoHealing] scan: ingested=${created.length} diagnosed=${diagnosed}`);
  return { ingested: created.length, diagnosed };
}

// Re-diagnostic à la demande d'un incident précis (bouton PDG).
export async function diagnoseOne(id: string): Promise<boolean> {
  const { data: inc } = await supabaseAdmin
    .from('auto_healing_incidents')
    .select('id, module, alert_key, severity, title, detail, context').eq('id', id).maybeSingle();
  if (!inc) return false;
  await runDualAIDiagnosis(inc as IncidentRow, await getLiveObservation());
  return true;
}

export async function listIncidents(status?: string, limit = 60): Promise<any[]> {
  let q = supabaseAdmin.from('auto_healing_incidents')
    .select('*').order('created_at', { ascending: false }).limit(Math.min(limit, 200));
  if (status) q = q.eq('status', status);
  const { data } = await q;
  return data || [];
}

// Le PDG marque un incident traité (résolu) ou l'escalade — pas d'exécution de code.
export async function setIncidentStatus(id: string, status: 'resolved' | 'escalated', adminId: string): Promise<boolean> {
  const patch: Record<string, any> = { status, updated_at: new Date().toISOString(), acknowledged_by: adminId };
  if (status === 'resolved') patch.applied_at = new Date().toISOString();
  const { error } = await supabaseAdmin.from('auto_healing_incidents').update(patch).eq('id', id);
  if (error) { logger.warn(`[autoHealing] setStatus failed: ${error.message}`); return false; }
  return true;
}

export function providersStatus() {
  return { openai: !!process.env.OPENAI_API_KEY, anthropic: !!process.env.ANTHROPIC_API_KEY };
}

// ── EXÉCUTION des remédiations SÛRES (idempotentes) via les jobs existants ──
// Chaque action auto_safe pointe vers un job déjà atomique. AUCUNE action argent ici
// (les needs_human sont bloquées : elles passent par la décision PDG, jamais l'exécuteur).
// Nettoyage SÛR des erreurs frontend mineures : marque résolues les erreurs mineures/modérées en
// attente (majorité = échecs de chargement d'images). NE TOUCHE JAMAIS les 'critique' (status/severity).
async function cleanupFrontendErrors(): Promise<{ ok: boolean; error?: string }> {
  try {
    // ⚠️ PostgREST plante (42703) si on met .or() DANS un UPDATE → on SÉLECTIONNE les ids d'abord,
    // puis on UPDATE par id (par lots). Le .or() en SELECT fonctionne, lui.
    const { data: rows, error: selErr } = await supabaseAdmin.from('system_errors')
      .select('id')
      .in('severity', ['mineure', 'modérée'])
      .or('fix_applied.is.null,fix_applied.eq.false')
      .limit(5000);
    if (selErr) return { ok: false, error: selErr.message };
    const ids = (rows || []).map((r: any) => r.id);
    if (!ids.length) return { ok: true };
    const now = new Date().toISOString();
    let done = 0;
    for (let i = 0; i < ids.length; i += 500) {
      const batch = ids.slice(i, i + 500);
      const { error } = await supabaseAdmin.from('system_errors')
        .update({ status: 'resolved', fix_applied: true, fixed_at: now })
        .in('id', batch);
      if (error) return { ok: false, error: error.message };
      done += batch.length;
    }
    logger.info(`[autoHealing] cleanup_frontend_errors: ${done} erreurs résolues`);
    return { ok: true };
  } catch (e: any) { return { ok: false, error: e?.message }; }
}

// Un exécuteur = soit un job atomique existant (job), soit une fonction directe sûre (fn).
const EXECUTORS: Record<string, { label: string; job?: string; fn?: () => Promise<{ ok: boolean; error?: string }> }> = {
  trigger_escrow_autorelease: { job: 'escrow.auto-release',        label: 'Libération des escrows échus' },
  rescrape_bcrg:              { job: 'fx.bcrg-live-check',         label: 'Rafraîchissement des taux BCRG' },
  run_subscription_expire:    { job: 'subscriptions.expire-check', label: 'Expiration des abonnements' },
  run_pos_reconciliation:     { job: 'pos.reconcile',             label: 'Réconciliation du stock POS' },
  cleanup_frontend_errors:    { fn: cleanupFrontendErrors,         label: 'Nettoyage des erreurs frontend mineures' },
};

export function isAutoExecutable(action: string | null): boolean {
  return !!action && !!EXECUTORS[action];
}

/**
 * Applique la remédiation d'un incident — UNIQUEMENT si elle est classée auto_safe ET
 * mappée à un exécuteur. Lance le job atomique correspondant, ATTEND son résultat et trace tout.
 * Refuse toute action needs_human (argent/sensible) : celles-ci restent une décision PDG.
 */
export async function applyRemediation(id: string, adminId: string): Promise<{ ok: boolean; error?: string }> {
  const { data: inc } = await supabaseAdmin
    .from('auto_healing_incidents').select('*').eq('id', id).maybeSingle();
  if (!inc) return { ok: false, error: 'Incident introuvable' };
  if ((inc as any).remediation_kind !== 'auto_safe' || !(inc as any).auto_apply_eligible) {
    return { ok: false, error: 'Action non auto-applicable : validation humaine requise.' };
  }
  const exec = EXECUTORS[(inc as any).final_action];
  if (!exec) return { ok: false, error: `Aucun exécuteur pour l'action ${(inc as any).final_action}` };

  logger.info(`[autoHealing] apply ${exec.job || exec.fn?.name} (incident ${id}) by ${adminId}`);
  const res = exec.fn ? await exec.fn() : await jobQueue.runNow(exec.job!);
  const now = new Date().toISOString();
  await supabaseAdmin.from('auto_healing_incidents').update({
    status: res.ok ? 'applied' : 'failed',
    applied_at: now, applied_by: adminId, updated_at: now,
    apply_result: { executor: exec.job || exec.label, ...res, at: now },
  }).eq('id', id);
  return res;
}

/** Ingest RAPIDE (sans LLM) des alertes actives + résumé des incidents ouverts (pour le panneau Surveillance). */
/**
 * Résumé LÉGER (1 requête) des incidents ouverts — SANS ré-ingestion. Utilisé par l'endpoint HTTP
 * PDG pour renvoyer les compteurs sans payer les ~100 aller-retours de ingestActiveAlerts (la
 * ré-ingestion est déjà assurée par le cycle 24/7 toutes les 60s).
 */
export async function summarizeOpenIncidents(): Promise<{ open: number; detected: number; proposed: number; escalated: number; ingested: number }> {
  const { data } = await supabaseAdmin
    .from('auto_healing_incidents').select('status')
    .not('status', 'in', '(resolved,applied,failed)');
  const rows = (data || []) as { status: string }[];
  return {
    open: rows.length,
    detected: rows.filter((r) => r.status === 'detected').length,
    proposed: rows.filter((r) => r.status === 'proposed').length,
    escalated: rows.filter((r) => r.status === 'escalated').length,
    ingested: 0,
  };
}

export async function ingestAndSummarize(): Promise<{ open: number; detected: number; proposed: number; escalated: number; ingested: number }> {
  const created = await ingestActiveAlerts();
  await ingestFrontendErrorsBacklog();
  const summary = await summarizeOpenIncidents();
  return { ...summary, ingested: created.length };
}
