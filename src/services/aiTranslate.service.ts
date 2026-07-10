import { logger } from '../config/logger.js';

/**
 * 🌍 Moteur de traduction texte 224SOLUTIONS — SANS Lovable.
 * Chaîne : Anthropic (claude haiku, économique) en PRIMAIRE → repli OpenAI (gpt-4o-mini)
 * si la clé Anthropic est absente OU si les crédits sont épuisés / erreur transitoire.
 * Best-effort : renvoie la traduction, ou null si aucun fournisseur n'a abouti
 * (l'appelant décide alors de garder l'original — jamais de faux texte).
 */

const LANGUAGE_NAMES: Record<string, string> = {
  fr: 'French', en: 'English', es: 'Spanish', pt: 'Portuguese', de: 'German',
  it: 'Italian', nl: 'Dutch', pl: 'Polish', ru: 'Russian', uk: 'Ukrainian',
  tr: 'Turkish', ar: 'Arabic', zh: 'Chinese (Simplified)', ja: 'Japanese',
  ko: 'Korean', hi: 'Hindi', bn: 'Bengali', vi: 'Vietnamese', th: 'Thai',
  id: 'Indonesian', sw: 'Swahili', he: 'Hebrew', fa: 'Persian (Farsi)',
  wo: 'Wolof', ff: 'Pulaar/Fulani', su: 'Susu (Soussou)', ha: 'Hausa',
  yo: 'Yoruba', ig: 'Igbo', bm: 'Bambara', ln: 'Lingala', am: 'Amharic',
};

const ANTHROPIC_MODEL = 'claude-haiku-4-5-20251001';
const OPENAI_MODEL = 'gpt-4o-mini';

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function buildPrompt(content: string, sourceLanguage: string, targetLanguage: string, context: string) {
  const tgt = LANGUAGE_NAMES[targetLanguage] || targetLanguage;
  const src = sourceLanguage ? (LANGUAGE_NAMES[sourceLanguage] || sourceLanguage) : 'the detected language';
  const system = 'You are a professional chat translator for the 224SOLUTIONS app (West African marketplace). Reply with ONLY the translation, no explanation, no quotes.';
  const user = `Translate the following chat message from ${src} to ${tgt}.\nRULES: keep the exact meaning and tone; natural, fluent (not word-for-word); DO NOT translate proper nouns, amounts/currencies (e.g. 50000 GNF), phone numbers, reference codes/IDs; keep emojis as-is. Context: ${context}.\n\nMESSAGE:\n${content}\n\nTRANSLATION:`;
  return { system, user };
}

/** Anthropic (haiku). Renvoie la traduction, ou null (clé absente / crédits épuisés / erreur). */
async function translateAnthropic(system: string, user: string): Promise<string | null> {
  const key = process.env.ANTHROPIC_API_KEY;
  if (!key) return null;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const r = await fetch('https://api.anthropic.com/v1/messages', {
        method: 'POST',
        headers: { 'x-api-key': key, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
        body: JSON.stringify({ model: ANTHROPIC_MODEL, max_tokens: 1000, system, messages: [{ role: 'user', content: user }] }),
      });
      if (r.ok) {
        const d: any = await r.json();
        const txt = (Array.isArray(d.content) ? d.content.find((c: any) => c.type === 'text')?.text : '') || '';
        return txt.trim() || null;
      }
      // 429 (rate limit / crédits) ou 5xx → transitoire : on retente puis on basculera OpenAI.
      if (r.status === 429 || r.status >= 500) {
        logger.warn(`[aiTranslate] Anthropic ${r.status}, retry ${attempt + 1}/3`);
        await sleep(600 * Math.pow(2, attempt));
        continue;
      }
      // 400/401/403 (clé invalide, crédits insuffisants renvoyés en 400) → inutile de retenter → repli OpenAI.
      logger.warn(`[aiTranslate] Anthropic ${r.status} → bascule OpenAI`);
      return null;
    } catch (e: any) {
      logger.warn(`[aiTranslate] Anthropic err (tentative ${attempt + 1}): ${e?.message}`);
      await sleep(600 * Math.pow(2, attempt));
    }
  }
  return null;
}

/** OpenAI (gpt-4o-mini) — repli. Renvoie la traduction, ou null. */
async function translateOpenAI(system: string, user: string): Promise<string | null> {
  const key = process.env.OPENAI_API_KEY;
  if (!key) return null;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const r = await fetch('https://api.openai.com/v1/chat/completions', {
        method: 'POST',
        headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ model: OPENAI_MODEL, temperature: 0.3, max_tokens: 1000, messages: [{ role: 'system', content: system }, { role: 'user', content: user }] }),
      });
      if (r.ok) {
        const d: any = await r.json();
        return d.choices?.[0]?.message?.content?.trim() || null;
      }
      if (r.status === 429 || r.status >= 500) {
        logger.warn(`[aiTranslate] OpenAI ${r.status}, retry ${attempt + 1}/3`);
        await sleep(600 * Math.pow(2, attempt));
        continue;
      }
      logger.error(`[aiTranslate] OpenAI ${r.status}: ${(await r.text()).slice(0, 200)}`);
      return null;
    } catch (e: any) {
      logger.warn(`[aiTranslate] OpenAI err (tentative ${attempt + 1}): ${e?.message}`);
      await sleep(600 * Math.pow(2, attempt));
    }
  }
  return null;
}

/**
 * Traduit `content` de sourceLanguage (ISO, '' = auto) vers targetLanguage (ISO).
 * Anthropic haiku PRIMAIRE, repli OpenAI. Renvoie null si aucun fournisseur n'aboutit.
 */
export async function aiTranslate(
  content: string,
  sourceLanguage: string,
  targetLanguage: string,
  context = 'general',
): Promise<string | null> {
  if (!content || !content.trim()) return null;
  const { system, user } = buildPrompt(content, sourceLanguage, targetLanguage, context);

  const viaAnthropic = await translateAnthropic(system, user);
  if (viaAnthropic) return viaAnthropic;

  // Crédits Anthropic épuisés / clé absente / erreur → repli OpenAI.
  return translateOpenAI(system, user);
}

/** Indique quels fournisseurs de traduction sont configurés (diagnostic). */
export function translationProvidersStatus() {
  return { anthropic: !!process.env.ANTHROPIC_API_KEY, openai: !!process.env.OPENAI_API_KEY };
}
