/**
 * 👻 FATOME FONCTIONNALITÉS — l'exécuteur de sondes + la CASCADE DE DIAGNOSTIC (§8.1/8.2)
 * et le CERVEAU IA (§8.5). Leader-gardé, heartbeat au contrat commun (§9.1).
 *
 * Ce que fait un cycle :
 *  1. charge les sondes dues (cadence par criticité : critique 2 min, haute 10 min, normale 1 h) ;
 *  2. exécute chacune EN LECTURE SEULE (invariant SQL nommé, disponibilité générique depuis le
 *     manifeste, ou santé d'un service externe) ;
 *  3. sur échec → CASCADE : localisation (couche), cause probable (mapping des codes Postgres),
 *     corrélation temporelle (dernière migration), impact (sondes voisines) → verdict structuré
 *     dans fatome_feature_incidents + anomalie Fatome (+ SMS si critique via le dispatch existant) ;
 *  4. sur retour au vert → résolution de l'incident ;
 *  5. journalise chaque run (uptime 7 j) et bat le heartbeat.
 *
 * GARDE-FOUS : aucune écriture métier, aucun SQL arbitraire (les invariants vivent en base),
 * l'IA DIAGNOSTIQUE mais n'exécute JAMAIS rien, et son indisponibilité ne dégrade que le confort.
 */
import { logger } from '../config/logger.js';
import { supabaseAdmin } from '../config/supabase.js';

const INTERVAL_MS = Number(process.env.FATOME_PROBE_INTERVAL_MS || 120_000); // tick 2 min
const CADENCE_SEC: Record<string, number> = { critical: 120, high: 600, normal: 3600 };
const AI_MAX_PER_DAY = Number(process.env.FATOME_AI_MAX_PER_DAY || 20);
const AI_MODEL_TRIAGE = 'claude-haiku-4-5-20251001';
const AI_MODEL_DEEP = 'claude-sonnet-5';

interface ProbeRow {
  probe_key: string; feature_key: string; probe_kind: string;
  label: string; config: Record<string, unknown>; criticality: string;
}
interface ProbeResult {
  ok: boolean; layer?: string; error_code?: string; message?: string;
  [k: string]: unknown;
}

/** Cause probable à partir d'un code d'erreur — la connaissance « experte » de la cascade (8.2.2). */
function causeOf(code?: string, layer?: string): string {
  switch (String(code || '')) {
    case '42703': return 'Colonne manquante — migration incompatible avec le code';
    case '42P01': return 'Table/vue absente — migration de renommage ou suppression';
    case '42883': return 'Fonction RPC absente — supprimée ou renommée par une migration';
    case '42501': return 'RLS/permission refuse l\'accès (GRANT ou policy retirée)';
    case '57014': case 'ETIMEDOUT': return 'Timeout — surcharge base ou service externe lent';
    case 'FX_STALE': return 'Taux de change périmés — collecteur en panne ou source injoignable';
    case 'NO_CHECK_DEFINED': return 'Sonde déclarée sans contrôle implémenté (à écrire)';
    case 'UNKNOWN_FEATURE': return 'Fonctionnalité absente du manifeste';
    case 'HTTP_5XX': return 'Service externe en erreur';
    default:
      if (String(code || '').startsWith('INVARIANT_')) return 'Règle métier violée — les données ne respectent plus l\'invariant';
      return layer === 'external' ? 'Service externe indisponible' : 'Échec non catalogué — voir le message';
  }
}

class FatomeFeaturesService {
  private interval: ReturnType<typeof setInterval> | null = null;
  private running = false;
  private cycle = 0;
  private lastRun = new Map<string, number>();
  private aiCallsToday = 0;
  private aiDay = '';

  start(): void {
    if (this.interval) return;
    logger.info(`[FatomeFeatures] Exécuteur de sondes actif (tick ${INTERVAL_MS}ms)`);
    void this.runOnce();
    this.interval = setInterval(() => { void this.runOnce(); }, INTERVAL_MS);
  }
  stop(): void { if (this.interval) { clearInterval(this.interval); this.interval = null; } }

  /** Charge le manifeste versionné en base (appelé au boot du leader). */
  async loadManifest(entries: unknown[], probes: unknown[], commit?: string): Promise<void> {
    try {
      const { data: m } = await supabaseAdmin.rpc('fatome_manifest_upsert' as any, {
        p_entries: entries, p_commit: commit || null,
      });
      const { data: p } = await supabaseAdmin.rpc('fatome_probes_upsert' as any, { p_probes: probes });
      const { data: d } = await supabaseAdmin.rpc('fatome_probes_ensure_default' as any, {});
      logger.info(`[FatomeFeatures] Manifeste chargé: ${JSON.stringify(m)} sondes: ${JSON.stringify(p)} défauts: ${d}`);
    } catch (e: any) {
      logger.warn(`[FatomeFeatures] chargement manifeste échoué: ${e?.message || e}`);
    }
  }

  private due(p: ProbeRow): boolean {
    const last = this.lastRun.get(p.probe_key) || 0;
    return Date.now() - last >= (CADENCE_SEC[p.criticality] ?? 3600) * 1000;
  }

  private async runOnce(): Promise<void> {
    if (this.running) return;
    this.running = true;
    const t0 = Date.now();
    let ok = true; let err: string | null = null; let executed = 0; let failed = 0;
    try {
      this.cycle++;
      const { data: probes, error } = await supabaseAdmin
        .from('fatome_feature_probes').select('*').eq('enabled', true);
      if (error) throw new Error(`registre sondes: ${error.message}`);

      for (const p of ((probes || []) as ProbeRow[]).filter((x) => this.due(x))) {
        const started = Date.now();
        let res: ProbeResult;
        try {
          res = await this.execute(p);
        } catch (e: any) {
          res = { ok: false, layer: 'probe', error_code: 'PROBE_CRASH', message: String(e?.message || e).slice(0, 300) };
        }
        this.lastRun.set(p.probe_key, Date.now());
        executed++;
        const duration = Date.now() - started;

        await supabaseAdmin.from('fatome_probe_runs').insert({
          probe_key: p.probe_key, feature_key: p.feature_key, ok: res.ok,
          duration_ms: duration, layer: res.layer || null,
          error_code: res.error_code || null, message: String(res.message || '').slice(0, 500),
        });

        if (!res.ok) { failed++; await this.openIncident(p, res); }
        else await this.closeIncident(p);
      }

      // Filet d'exécution (8.6.3) : routes servies hors manifeste — 1×/h.
      if (this.cycle === 1 || this.cycle % 30 === 0) {
        try { await supabaseAdmin.rpc('fatome_unregistered_routes_check' as any, {}); }
        catch (e: any) { logger.warn(`[FatomeFeatures] contrôle routes non mémorisées: ${e?.message || e}`); }
      }
    } catch (e: any) {
      ok = false; err = String(e?.message || e).slice(0, 500);
      logger.warn(`[FatomeFeatures] cycle en erreur: ${err}`);
    } finally {
      try {
        await supabaseAdmin.rpc('fatome_beat' as any, { p_key: 'fatome_fonctionnalites', p_ok: ok, p_error: err });
      } catch { /* best-effort */ }
      try {
        await supabaseAdmin.from('fatome_activity_log').insert({
          fatome_key: 'fatome_fonctionnalites', duration_ms: Date.now() - t0, ok,
          message: ok ? `Cycle ${this.cycle} : ${executed} sonde(s), ${failed} en échec` : `Cycle en erreur : ${err}`,
          volume: { cycle: this.cycle, executed, failed },
        });
      } catch { /* best-effort */ }
      this.running = false;
    }
  }

  /** Exécute UNE sonde — lecture seule, jamais de SQL venu de la config. */
  private async execute(p: ProbeRow): Promise<ProbeResult> {
    if (p.probe_kind === 'invariant') {
      const { data, error } = await supabaseAdmin.rpc('fatome_probe_check' as any, { p_probe_key: p.probe_key });
      if (error) return { ok: false, layer: 'rpc', error_code: '42883', message: error.message };
      return (data || { ok: false, message: 'réponse vide' }) as ProbeResult;
    }
    if (p.probe_kind === 'availability') {
      const { data, error } = await supabaseAdmin.rpc('fatome_probe_availability' as any, { p_feature: p.feature_key });
      if (error) return { ok: false, layer: 'rpc', error_code: '42883', message: error.message };
      return (data || { ok: false, message: 'réponse vide' }) as ProbeResult;
    }
    if (p.probe_kind === 'external') {
      const url = String((p.config as any)?.url || '');
      if (!url) return { ok: false, layer: 'probe', error_code: 'NO_URL', message: 'sonde externe sans url' };
      try {
        const ctrl = new AbortController();
        const to = setTimeout(() => ctrl.abort(), 8000);
        const r = await fetch(url, { signal: ctrl.signal });
        clearTimeout(to);
        return r.ok
          ? { ok: true, layer: 'external', message: `HTTP ${r.status}` }
          : { ok: false, layer: 'external', error_code: r.status >= 500 ? 'HTTP_5XX' : `HTTP_${r.status}`, message: `HTTP ${r.status}` };
      } catch (e: any) {
        return { ok: false, layer: 'external', error_code: 'ETIMEDOUT', message: String(e?.message || e).slice(0, 200) };
      }
    }
    return { ok: false, layer: 'probe', error_code: 'UNKNOWN_KIND', message: `type de sonde inconnu: ${p.probe_kind}` };
  }

  /** CASCADE 8.2 : localiser → causer → corréler → mesurer l'impact → verdict + IA. */
  private async openIncident(p: ProbeRow, res: ProbeResult): Promise<void> {
    try {
      const layer = res.layer || 'unknown';
      const code = res.error_code || 'UNKNOWN';
      const signature = `${p.feature_key}|${layer}|${code}`;
      const causeLabel = causeOf(code, layer);

      // Corrélation temporelle : la dernière migration est le suspect n°1.
      let suspect: string | null = null;
      try {
        const { data: chg } = await supabaseAdmin.rpc('fatome_recent_changes' as any, {});
        const last = (chg as any)?.recent_migrations?.[0];
        if (last) suspect = `migration ${last.version} (${last.name || '—'})`;
      } catch { /* best-effort */ }

      // Impact : combien de sondes de CETTE interface sont au rouge (périmètre exact).
      let impact = `Fonctionnalité « ${p.feature_key} » dégradée`;
      try {
        const { data: sib } = await supabaseAdmin
          .from('fatome_feature_manifest').select('feature_key').eq(
            'interface',
            (await supabaseAdmin.from('fatome_feature_manifest').select('interface')
              .eq('feature_key', p.feature_key).maybeSingle()).data?.interface || '',
          );
        const keys = (sib || []).map((s: any) => s.feature_key);
        if (keys.length) {
          const { data: open } = await supabaseAdmin
            .from('fatome_feature_incidents').select('feature_key')
            .in('feature_key', keys).is('resolved_at', null);
          const n = new Set((open || []).map((o: any) => o.feature_key)).size + 1;
          impact = n > 1
            ? `${n}/${keys.length} fonctionnalités de cette interface touchées`
            : `Isolé : seule « ${p.feature_key} » est touchée (${keys.length - 1} voisines OK)`;
        }
      } catch { /* best-effort */ }

      const severity = p.criticality === 'critical' ? 'critical' : p.criticality === 'high' ? 'high' : 'medium';
      const { data: inc } = await supabaseAdmin.rpc('fatome_incident_open' as any, {
        p_feature: p.feature_key, p_signature: signature, p_layer: layer,
        p_cause_code: code, p_cause_label: causeLabel, p_suspect: suspect,
        p_impact: impact,
        p_detail: { probe: p.probe_key, probe_label: p.label, message: res.message, raw: res },
        p_severity: severity,
      });

      // CERVEAU IA (8.5) : uniquement sur un NOUVEL incident (jamais les répétitions).
      if ((inc as any)?.new && (inc as any)?.incident_id) {
        void this.diagnose(Number((inc as any).incident_id), p, res, signature, causeLabel, suspect, impact);
      }
    } catch (e: any) {
      logger.warn(`[FatomeFeatures] ouverture incident ${p.feature_key}: ${e?.message || e}`);
    }
  }

  private async closeIncident(p: ProbeRow): Promise<void> {
    try { await supabaseAdmin.rpc('fatome_incident_resolve' as any, { p_feature: p.feature_key, p_resolution: 'probe_ok' }); }
    catch { /* best-effort */ }
  }

  /**
   * §8.5 — DIAGNOSTIC IA. L'IA lit un dossier (verdict + manifeste + incidents similaires) et
   * rend un JSON structuré. Elle n'a AUCUN accès en écriture et ne déclenche AUCUNE action.
   * Budget plafonné/jour ; API absente ou en erreur → la cascade reste le diagnostic (dégradé propre).
   */
  private async diagnose(
    incidentId: number, p: ProbeRow, res: ProbeResult, signature: string,
    causeLabel: string, suspect: string | null, impact: string,
  ): Promise<void> {
    const key = process.env.ANTHROPIC_API_KEY;
    if (!key) return;
    const day = new Date().toISOString().slice(0, 10);
    if (this.aiDay !== day) { this.aiDay = day; this.aiCallsToday = 0; }
    if (this.aiCallsToday >= AI_MAX_PER_DAY) {
      logger.info('[FatomeFeatures] budget IA du jour atteint — cascade seule');
      return;
    }
    this.aiCallsToday++;

    try {
      const { data: feature } = await supabaseAdmin
        .from('fatome_feature_manifest').select('*').eq('feature_key', p.feature_key).maybeSingle();
      const { data: similar } = await supabaseAdmin.rpc('fatome_similar_incidents' as any, {
        p_signature: signature, p_limit: 3,
      });
      const { data: changes } = await supabaseAdmin.rpc('fatome_recent_changes' as any, {});

      const dossier = {
        verdict_cascade: { couche: res.layer, code: res.error_code, cause_probable: causeLabel, suspect, impact, message: res.message },
        fonctionnalite: feature ? {
          cle: (feature as any).feature_key, label: (feature as any).label,
          interface: (feature as any).interface, routes: (feature as any).routes,
          rpcs: (feature as any).rpcs, tables: (feature as any).tables,
          invariants: (feature as any).invariants, depend_de: (feature as any).depends_on,
        } : null,
        changements_recents: changes,
        incidents_similaires_resolus: similar,
      };

      const model = p.criticality === 'critical' ? AI_MODEL_DEEP : AI_MODEL_TRIAGE;
      const prompt = `Tu es l'expert diagnostic de la plateforme 224Solutions. Une sonde de surveillance vient d'échouer.
Dossier (JSON) :
${JSON.stringify(dossier).slice(0, 12000)}

Réponds UNIQUEMENT par un JSON valide, sans texte autour, avec EXACTEMENT ces clés :
{"cause_racine": "...", "confiance": 0-100, "explication_pdg": "2 phrases maximum, français simple, sans jargon",
 "chaine_causale": ["étape 1", "étape 2", "étape 3"], "correctif_suggere": "action concrète pour un développeur",
 "incident_similaire": "référence à un incident passé résolu, ou null"}`;

      const ctrl = new AbortController();
      const to = setTimeout(() => ctrl.abort(), 25_000);
      const r = await fetch('https://api.anthropic.com/v1/messages', {
        method: 'POST', signal: ctrl.signal,
        headers: { 'content-type': 'application/json', 'x-api-key': key, 'anthropic-version': '2023-06-01' },
        body: JSON.stringify({ model, max_tokens: 700, messages: [{ role: 'user', content: prompt }] }),
      });
      clearTimeout(to);
      if (!r.ok) { logger.warn(`[FatomeFeatures] IA HTTP ${r.status} — cascade seule`); return; }

      const body: any = await r.json();
      const text = String(body?.content?.[0]?.text || '');
      // Parsing DÉFENSIF (§11.7) : le JSON de l'IA est une DONNÉE, jamais une instruction.
      const match = text.match(/\{[\s\S]*\}/);
      if (!match) { logger.warn('[FatomeFeatures] réponse IA non parsable — cascade seule'); return; }
      let parsed: any;
      try { parsed = JSON.parse(match[0]); } catch { logger.warn('[FatomeFeatures] JSON IA invalide'); return; }

      const clean = {
        cause_racine: String(parsed.cause_racine || '').slice(0, 500),
        confiance: Math.max(0, Math.min(100, Number(parsed.confiance) || 0)),
        explication_pdg: String(parsed.explication_pdg || '').slice(0, 600),
        chaine_causale: Array.isArray(parsed.chaine_causale) ? parsed.chaine_causale.slice(0, 6).map((s: any) => String(s).slice(0, 200)) : [],
        correctif_suggere: String(parsed.correctif_suggere || '').slice(0, 600),
        incident_similaire: parsed.incident_similaire ? String(parsed.incident_similaire).slice(0, 300) : null,
        model, generated_at: new Date().toISOString(),
      };
      await supabaseAdmin.from('fatome_feature_incidents').update({ ai_diagnosis: clean }).eq('id', incidentId);
      logger.info(`[FatomeFeatures] 🧠 diagnostic IA posé sur l'incident ${incidentId} (confiance ${clean.confiance}%)`);
    } catch (e: any) {
      logger.warn(`[FatomeFeatures] diagnostic IA indisponible: ${e?.message || e} — cascade seule`);
    }
  }
}

export const fatomeFeaturesService = new FatomeFeaturesService();
