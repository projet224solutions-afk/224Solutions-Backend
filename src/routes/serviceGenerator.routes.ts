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
  try {
    const r = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'x-api-key': key, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
      body: JSON.stringify({ model: 'claude-sonnet-4-6', max_tokens: 900, system: SYSTEM_PROMPT, messages: [{ role: 'user', content: userMsg }] }),
    });
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
    logger.error(`[svcgen] IA: ${e?.message}`);
    return { success: false, code: 'AI_ERROR', error: 'Appel IA échoué.' };
  }
}

// ── BLOC 3 — POST /generate-config : IA → JSON → VALIDÉ serveur → renvoyé (éditable par le PDG) ──
router.post('/generate-config', verifyJWT, requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  const name = String(req.body?.name || '').trim();
  const category = String(req.body?.category || '').trim();
  const text = String(req.body?.text || '').trim();
  if (!name || !text) return fail(res, 400, 'Nom et description requis.', 'MISSING_FIELDS');

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
  const code = String(req.body?.code || name).trim();
  const commission = Number(req.body?.commission_rate);
  const config = req.body?.config;
  if (!name) return fail(res, 400, 'Nom requis.', 'MISSING_NAME');
  if (!config || typeof config !== 'object') return fail(res, 400, 'Configuration invalide.', 'INVALID_CONFIG');

  // Ceinture + bretelles : on ré-assainit ICI, et la RPC ré-assainit EN BASE (barrière ultime).
  const clean = sanitizeConfig(config, config?.prompt_source || '');
  const { data, error } = await supabaseAdmin.rpc('pdg_create_service_type', {
    p_code: code, p_name: name, p_category: category, p_config: clean,
    p_commission_rate: Number.isFinite(commission) ? commission : 5.0,
    p_actor: req.user?.id, p_raw_ai: req.body?.raw_ai_output ?? null,
  });
  if (error) {
    const dup = /CODE_DEJA_UTILISE/.test(error.message || '');
    return fail(res, dup ? 409 : 400, dup ? 'Ce code de service existe déjà.' : (error.message || 'Création refusée.'),
      dup ? 'CODE_EXISTS' : 'CREATE_FAILED');
  }
  return ok(res, data);
});

// ── BLOC 4/5 — GET / : liste des services (dont générés) pour l'écran PDG ──
router.get('/', verifyJWT, requireRole(PDG_ROLES), async (_req: AuthenticatedRequest, res: Response) => {
  const { data, error } = await supabaseAdmin.from('service_types')
    .select('id, code, name, category, is_active, commission_rate, config, created_at')
    .order('created_at', { ascending: false });
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
