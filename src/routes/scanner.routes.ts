/**
 * 📷 SCANNER DE TEXTE prestataire — OCR par VISION IA (réutilise l'infra du copilote : les
 * mêmes providers vision, AUCUNE lib OCR lourde). verifyJWT + rate-limit (facture IA protégée).
 * POST /api/v2/scanner/extract { image: dataURL ≤1024px } → { success, data: { text } }
 */
import { Router, Response } from 'express';
import { verifyJWT, AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { routeRateLimit } from '../middlewares/routeRateLimiter.js';
import { logger } from '../config/logger.js';
import { fail, ok } from '../utils/apiResponse.js';

const router = Router();

// 30 scans / jour / utilisateur (protège la facture IA sans frustrer — configurable ici).
const scanRateLimit = routeRateLimit({
  maxRequests: Number(process.env.SCAN_TEXT_DAILY_LIMIT || 30),
  windowSeconds: 24 * 60 * 60,
  keyPrefix: 'scan-text', perUser: true,
});

const SYSTEM = 'Extrais UNIQUEMENT le texte visible de cette image, fidèlement, sans commentaire ni interprétation. Conserve la structure (lignes, listes, titres). Le texte peut être en français ou en anglais, imprimé ou manuscrit. Réponds SEULEMENT avec le texte extrait. Si aucun texte n\'est lisible, réponds exactement: [AUCUN_TEXTE]';

function parseDataUrl(dataUrl: string): { mediaType: string; base64: string } | null {
  const m = /^data:(image\/(?:jpeg|png|webp));base64,(.+)$/.exec(dataUrl || '');
  if (!m) return null;
  if (m[2].length > 2_800_000) return null; // ~2 Mo base64 max (image déjà compressée client)
  return { mediaType: m[1], base64: m[2] };
}

async function visionAnthropic(key: string, img: { mediaType: string; base64: string }): Promise<string | null> {
  try {
    const r = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'x-api-key': key, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
      body: JSON.stringify({
        model: 'claude-sonnet-4-6', max_tokens: 1500, system: SYSTEM,
        messages: [{ role: 'user', content: [
          { type: 'image', source: { type: 'base64', media_type: img.mediaType, data: img.base64 } },
          { type: 'text', text: 'Extrais le texte.' },
        ] }],
      }),
    });
    if (!r.ok) { logger.warn(`[scanner] anthropic ${r.status}`); return null; }
    const data: any = await r.json();
    return (Array.isArray(data.content) ? data.content.find((c: any) => c.type === 'text')?.text : '')?.trim() || null;
  } catch (e: any) { logger.warn(`[scanner] anthropic err ${e?.message}`); return null; }
}

async function visionOpenAILike(key: string, isLovable: boolean, dataUrl: string): Promise<string | null> {
  try {
    const endpoint = isLovable ? 'https://ai.gateway.lovable.dev/v1/chat/completions' : 'https://api.openai.com/v1/chat/completions';
    const model = isLovable ? 'google/gemini-2.5-flash' : 'gpt-4o-mini';
    const r = await fetch(endpoint, {
      method: 'POST',
      headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model, temperature: 0, max_tokens: 1500,
        messages: [
          { role: 'system', content: SYSTEM },
          { role: 'user', content: [
            { type: 'text', text: 'Extrais le texte.' },
            { type: 'image_url', image_url: { url: dataUrl } },
          ] },
        ],
      }),
    });
    if (!r.ok) { logger.warn(`[scanner] ${isLovable ? 'lovable' : 'openai'} ${r.status}`); return null; }
    const data: any = await r.json();
    return data.choices?.[0]?.message?.content?.trim() || null;
  } catch (e: any) { logger.warn(`[scanner] vision err ${e?.message}`); return null; }
}

router.post('/extract', verifyJWT, scanRateLimit, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const dataUrl = String(req.body?.image || '');
  const img = parseDataUrl(dataUrl);
  if (!img) { fail(res, 400, 'Image invalide (JPEG/PNG/WebP en dataURL, compressée)', 'BAD_IMAGE'); return; }

  // Redondance providers (même ordre que le copilote) — fail-closed si aucune clé.
  let text: string | null = null;
  if (process.env.ANTHROPIC_API_KEY) text = await visionAnthropic(process.env.ANTHROPIC_API_KEY, img);
  if (!text && process.env.LOVABLE_API_KEY) text = await visionOpenAILike(process.env.LOVABLE_API_KEY, true, dataUrl);
  if (!text && process.env.OPENAI_API_KEY) text = await visionOpenAILike(process.env.OPENAI_API_KEY, false, dataUrl);
  if (text === null) { fail(res, 503, 'Service d\'extraction momentanément indisponible', 'VISION_UNAVAILABLE'); return; }

  if (/^\[AUCUN_TEXTE\]$/i.test(text.trim())) { ok(res, { text: '', empty: true }); return; }
  ok(res, { text: text.slice(0, 20000) });
});

export default router;
