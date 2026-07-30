/**
 * GÉNÉRATEUR DE SERVICES DE PROXIMITÉ SANS CODE — routes PDG (BLOC 2, 3, 5).
 *
 * PRINCIPE DE SÉCURITÉ ABSOLU : l'IA génère de la CONFIGURATION (données), JAMAIS du code.
 * On ne `eval` rien, on n'exécute NI le texte du PDG NI la sortie IA. La sortie IA est PARSÉE,
 * FILTRÉE contre une WHITELIST FERMÉE (côté serveur ici + côté base dans sanitize_service_config),
 * bornée, puis stockée en JSONB. La whitelist est la SEULE source de ce qu'un service peut faire ;
 * l'IA ne l'élargit jamais. Accès strictement PDG (verifyJWT + requireRole).
 */
import { Router, Response } from 'express';
import { verifyJWT, requireRole } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { ok, fail } from '../utils/apiResponse.js';
import { logger } from '../config/logger.js';

const router = Router();
const PDG_ROLES = ['admin', 'pdg', 'ceo'];

// ── WHITELIST FERMÉE (miroir EXACT de service_generator_whitelist() en base) ──
const CAPABILITIES = ['booking', 'quote', 'catalog', 'delivery', 'reviews', 'media', 'opening_hours'] as const;
const FIELD_TYPES = ['text', 'textarea', 'number', 'date', 'time', 'select', 'phone', 'boolean'] as const;
const LIMITS = { maxFields: 20, maxLabel: 60, maxKey: 40, maxOptions: 12 };

interface GeneratedField { key: string; label: string; type: string; required: boolean; options?: string[]; }
interface ServiceConfig {
  capabilities: Record<string, { enabled: boolean }>;
  custom_fields: GeneratedField[];
  description_generated: string;
  generated_by_ai: boolean;
  generated_at: string;
  prompt_source: string;
}

/** Assainit une config quelconque → ne garde QUE le whitelisté, borné. Miroir de la fonction SQL. */
function sanitizeConfig(raw: any, promptSource = ''): ServiceConfig {
  const caps: Record<string, { enabled: boolean }> = {};
  const rawCaps = (raw && typeof raw.capabilities === 'object' && raw.capabilities) || {};
  for (const c of CAPABILITIES) {
    if (c in rawCaps) caps[c] = { enabled: Boolean(rawCaps[c]?.enabled) };
  }
  const fields: GeneratedField[] = [];
  const rawFields = Array.isArray(raw?.custom_fields) ? raw.custom_fields : [];
  for (const f of rawFields) {
    if (fields.length >= LIMITS.maxFields) break;
    const type = String(f?.type || 'text').toLowerCase();
    if (!(FIELD_TYPES as readonly string[]).includes(type)) continue;      // type hors whitelist → ignoré
    const key = String(f?.key || '').toLowerCase().replace(/[^a-z0-9_]/g, '_').slice(0, LIMITS.maxKey);
    if (!key) continue;
    const label = String(f?.label || key).slice(0, LIMITS.maxLabel);
    const out: GeneratedField = { key, label, type, required: Boolean(f?.required) };
    if (type === 'select' && Array.isArray(f?.options)) {
      out.options = f.options.slice(0, LIMITS.maxOptions).map((o: any) => String(o).slice(0, LIMITS.maxLabel));
    }
    fields.push(out);
  }
  return {
    capabilities: caps,
    custom_fields: fields,
    description_generated: String(raw?.description_generated || '').slice(0, 2000),
    generated_by_ai: true,
    generated_at: new Date().toISOString(),
    prompt_source: String(promptSource || '').slice(0, 2000),
  };
}

// ── Appel IA (même fournisseur que les copilotes) — SORTIE JSON STRICTE ──
const SYSTEM_PROMPT = `Tu es un générateur de CONFIGURATION de service (données), PAS un générateur de code.
Tu réponds UNIQUEMENT par un objet JSON pur (aucun texte autour, aucun bloc markdown), conforme à ce schéma :
{
  "capabilities": { "<capacité>": { "enabled": true|false }, ... },
  "custom_fields": [ { "key": "slug_minuscule", "label": "Libellé", "type": "<type>", "required": true|false, "options": ["..."] } ],
  "description_generated": "1-2 phrases décrivant le service"
}
CAPACITÉS AUTORISÉES (whitelist FERMÉE, aucune autre n'est permise) : ${CAPABILITIES.join(', ')}.
TYPES DE CHAMP AUTORISÉS : ${FIELD_TYPES.join(', ')} ("options" seulement pour type "select").
INTERDIT ABSOLU : inventer une capacité hors liste, écrire du code, référencer wallet/paiement/QR/ID/auth
(ces briques sont automatiques et hors de ta portée). Maximum ${LIMITS.maxFields} champs. Réponds en JSON pur.`;

// Champs optionnels (le repo backend n'a pas strictNullChecks → pas de narrowing d'union discriminée).
interface AiGenResult { success: boolean; raw?: any; code?: string; error?: string; }
async function generateWithAI(userText: string, name: string, category: string): Promise<AiGenResult> {
  const key = process.env.ANTHROPIC_API_KEY?.trim();
  if (!key) return { success: false, code: 'AI_NOT_CONFIGURED', error: "Le fournisseur IA n'est pas configuré (ANTHROPIC_API_KEY absente)." };
  const userMsg = `Service : « ${name} » (catégorie : ${category || 'non précisée'}).\nFonctionnement souhaité par le PDG :\n${userText}`;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 20000); // B4 : timeout dur → jamais de blocage
  try {
    const r = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'x-api-key': key, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
      body: JSON.stringify({ model: 'claude-sonnet-4-6', max_tokens: 900, system: SYSTEM_PROMPT, messages: [{ role: 'user', content: userMsg }] }),
      signal: controller.signal,
    });
    clearTimeout(timer);
    if (!r.ok) return { success: false, code: 'AI_ERROR', error: `Fournisseur IA : ${r.status}` };
    const data: any = await r.json();
    const text = (data?.content?.find?.((c: any) => c.type === 'text')?.text || '').trim();
    // Extraire le JSON même si l'IA a ajouté du texte / des fences (défensif).
    const match = text.match(/\{[\s\S]*\}/);
    if (!match) return { success: false, code: 'AI_BAD_OUTPUT', error: 'Sortie IA sans JSON exploitable.' };
    let parsed: any;
    try { parsed = JSON.parse(match[0]); }
    catch { return { success: false, code: 'AI_BAD_JSON', error: 'Sortie IA : JSON malformé.' }; }
    return { success: true, raw: parsed };
  } catch (e: any) {
    clearTimeout(timer);
    const timedOut = e?.name === 'AbortError';
    logger.error(`[svcgen] IA: ${timedOut ? 'timeout' : e?.message}`);
    return { success: false, code: 'AI_ERROR', error: timedOut ? "Le fournisseur IA n'a pas répondu à temps." : 'Appel IA échoué.' };
  }
}

// ── B2 — Rate-limit génération IA (coût réel) : par PDG/jour + plafond GLOBAL/jour avec alerte. ──
const GEN_PER_PDG_DAILY = 30;
const GEN_GLOBAL_DAILY = 200;
async function checkGenerationQuota(actorId?: string): Promise<{ ok: boolean; code?: string; error?: string }> {
  const since = new Date(); since.setHours(0, 0, 0, 0);
  const iso = since.toISOString();
  const perPdg = await supabaseAdmin.from('service_type_generation_log')
    .select('id', { count: 'exact', head: true }).eq('action', 'generate').eq('actor_user_id', actorId || '').gte('created_at', iso);
  if ((perPdg.count ?? 0) >= GEN_PER_PDG_DAILY) {
    return { ok: false, code: 'RATE_LIMIT', error: `Limite quotidienne de génération atteinte (${GEN_PER_PDG_DAILY}/jour). Réessayez demain.` };
  }
  const global = await supabaseAdmin.from('service_type_generation_log')
    .select('id', { count: 'exact', head: true }).eq('action', 'generate').gte('created_at', iso);
  if ((global.count ?? 0) >= GEN_GLOBAL_DAILY) {
    await supabaseAdmin.from('system_alerts').insert({
      severity: 'warning', module: 'service_generator', title: 'Plafond IA quotidien atteint',
      message: `Le générateur de services a atteint ${GEN_GLOBAL_DAILY} générations aujourd'hui — appels IA suspendus jusqu'à demain.`,
      metadata: { global_count: global.count },
    }).then(() => {}, () => {});
    return { ok: false, code: 'AI_DAILY_CAP', error: 'Plafond quotidien de génération IA atteint. Réessayez demain.' };
  }
  return { ok: true };
}

// ── BLOC 3 — POST /generate-config : IA → JSON → VALIDÉ serveur → renvoyé (éditable par le PDG) ──
router.post('/generate-config', verifyJWT, requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  const name = String(req.body?.name || '').trim();
  const category = String(req.body?.category || '').trim();
  const text = String(req.body?.text || '').trim();
  if (!name || !text) return fail(res, 400, 'Nom et description requis.', 'MISSING_FIELDS');

  // B2 : quota (par PDG + plafond global/jour) AVANT tout appel IA (coût réel).
  const quota = await checkGenerationQuota(req.user?.id);
  if (!quota.ok) return fail(res, 429, quota.error || 'Quota atteint.', quota.code || 'RATE_LIMIT');

  const gen = await generateWithAI(text, name, category);
  if (!gen.success) {
    const status = gen.code === 'AI_NOT_CONFIGURED' ? 503 : 502;
    return fail(res, status, gen.error || 'Génération IA échouée.', gen.code || 'AI_ERROR');
  }

  // VALIDATION SERVEUR : on ne renvoie JAMAIS la sortie IA brute — seulement l'assainie (whitelist).
  const clean = sanitizeConfig(gen.raw, text);
  // Journal (audit BLOC 5.3) : on garde le BRUT IA + l'assaini.
  await supabaseAdmin.from('service_type_generation_log').insert({
    action: 'generate', actor_user_id: req.user?.id, prompt_source: text.slice(0, 2000),
    raw_ai_output: gen.raw, final_config: clean,
  }).then(() => {}, () => {});

  return ok(res, { config: clean, whitelist: { capabilities: CAPABILITIES, field_types: FIELD_TYPES, limits: LIMITS } });
});

// ── BLOC 2 — POST /create : le PDG valide la config (éventuellement éditée) → insertion ──
router.post('/create', verifyJWT, requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  const name = String(req.body?.name || '').trim();
  const category = String(req.body?.category || '').trim();
  const rawCode = String(req.body?.code || name).trim();
  const commission = Number(req.body?.commission_rate);
  const config = req.body?.config;
  if (!name) return fail(res, 400, 'Nom requis.', 'MISSING_NAME');
  if (!config || typeof config !== 'object') return fail(res, 400, 'Configuration invalide.', 'INVALID_CONFIG');

  // B6 : `code` = slug SÛR. Dérivé du nom si absent, slugifié, PUIS validé strictement → aucune injection.
  const code = rawCode.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '')
    .replace(/[^a-z0-9_-]/g, '-').replace(/-+/g, '-').replace(/^-|-$/g, '').slice(0, 40);
  if (!/^[a-z0-9_-]{2,40}$/.test(code)) {
    return fail(res, 400, 'Code de service invalide (2 à 40 caractères : lettres, chiffres, _ ou -).', 'INVALID_CODE');
  }

  // C2 : ALERTE si une capacité HORS whitelist a été soumise (signal de tentative d'élargissement).
  const rawCaps = (config.capabilities && typeof config.capabilities === 'object') ? Object.keys(config.capabilities) : [];
  const filtered = rawCaps.filter((c) => !(CAPABILITIES as readonly string[]).includes(c));
  if (filtered.length) {
    await supabaseAdmin.from('system_alerts').insert({
      severity: 'warning', module: 'service_generator', title: 'Capacité hors whitelist filtrée',
      message: `Création « ${name} » : capacité(s) hors whitelist ignorée(s) : ${filtered.join(', ')}.`,
      metadata: { actor: req.user?.id, filtered },
    }).then(() => {}, () => {});
  }

  // BLINDAGE : on passe la config ORIGINALE à la RPC — c'est la BASE (sanitize_service_config) qui
  // est l'autorité finale : elle REJETTE les bornes dépassées et FILTRE le hors-whitelist, puis stocke
  // la version nettoyée (jamais la version reçue telle quelle). La création + l'audit sont atomiques (1 RPC).
  const { data, error } = await supabaseAdmin.rpc('pdg_create_service_type', {
    p_code: code, p_name: name, p_category: category, p_config: config,
    p_commission_rate: Number.isFinite(commission) ? commission : 5.0,
    p_actor: req.user?.id, p_raw_ai: req.body?.raw_ai_output ?? null,
  });
  if (error) {
    const msg = error.message || '';
    if (/CODE_DEJA_UTILISE/.test(msg)) return fail(res, 409, 'Ce code de service existe déjà.', 'CODE_EXISTS');
    if (/TROP_DE_CHAMPS|TROP_DE_CAPACITES|DESCRIPTION_TROP_LONGUE|CONFIG_INVALIDE/.test(msg)) {
      await supabaseAdmin.from('system_alerts').insert({
        severity: 'warning', module: 'service_generator', title: 'Config hors bornes rejetée',
        message: `Création « ${name} » rejetée (bornes) : ${msg}`, metadata: { actor: req.user?.id },
      }).then(() => {}, () => {});
      return fail(res, 400, `Configuration hors limites : ${msg}`, 'CONFIG_OUT_OF_BOUNDS');
    }
    return fail(res, 400, msg || 'Création refusée.', 'CREATE_FAILED');
  }
  return ok(res, data);
});

// ── C3 — GET / : vue de supervision (services + créateur + actif + nb prestataires rattachés) ──
router.get('/', verifyJWT, requireRole(PDG_ROLES), async (_req: AuthenticatedRequest, res: Response) => {
  const { data, error } = await supabaseAdmin.rpc('pdg_service_types_overview');
  if (error) return fail(res, 500, error.message, 'LIST_FAILED');
  return ok(res, data);
});

// ── BLOC 5.4 — PATCH /:code/toggle : désactiver/réactiver (soft, sans supprimer) ──
router.patch('/:code/toggle', verifyJWT, requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  const code = String(req.params.code || '').toLowerCase();
  const active = Boolean(req.body?.is_active);
  const { error } = await supabaseAdmin.from('service_types').update({ is_active: active, updated_at: new Date().toISOString() }).eq('code', code);
  if (error) return fail(res, 500, error.message, 'TOGGLE_FAILED');
  await supabaseAdmin.from('service_type_generation_log').insert({
    service_code: code, action: 'toggle', actor_user_id: req.user?.id, final_config: { is_active: active },
  }).then(() => {}, () => {});
  return ok(res, { code, is_active: active });
});

export default router;
