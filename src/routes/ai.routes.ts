/**
 * 🤖 Routes IA canoniques — /api/v2/ai/*
 *   POST /api/v2/ai/translate → traduction texte (Anthropic haiku primaire, repli OpenAI ; SANS Lovable).
 */
import { Router, Response } from 'express';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { ok, fail } from '../utils/apiResponse.js';
import { aiTranslate, translationProvidersStatus } from '../services/aiTranslate.service.js';
import { logger } from '../config/logger.js';

const router = Router();

router.post('/translate', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const b = req.body || {};
    const text: string = (b.text ?? b.content ?? '').toString();
    const targetLanguage: string = (b.target_language ?? b.targetLanguage ?? '').toString();
    const sourceLanguageRaw: string = (b.source_language ?? b.sourceLanguage ?? '').toString();
    const context: string = (b.context ?? 'general').toString();

    if (!text.trim()) { fail(res, 400, 'text requis', 'TEXT_REQUIRED'); return; }
    if (!targetLanguage) { fail(res, 400, 'target_language requis', 'TARGET_REQUIRED'); return; }
    // Garde-fou de coût : longueur bornée.
    if (text.length > 5000) { fail(res, 413, 'Texte trop long (max 5000 caractères)', 'TEXT_TOO_LONG'); return; }

    // Langues identiques (source explicite) → pas de coût de traduction.
    if (sourceLanguageRaw && sourceLanguageRaw === targetLanguage) {
      ok(res, { translated: text, source_language: sourceLanguageRaw, target_language: targetLanguage, was_translated: false });
      return;
    }

    // Secret UNIQUEMENT en env (jamais de repli DB) → échec explicite si rien n'est configuré.
    const providers = translationProvidersStatus();
    if (!providers.anthropic && !providers.openai) {
      fail(res, 503, 'Traduction indisponible (aucun fournisseur IA configuré)', 'AI_NOT_CONFIGURED');
      return;
    }

    const source = sourceLanguageRaw === 'auto' ? '' : sourceLanguageRaw;
    const translated = await aiTranslate(text, source, targetLanguage, context);
    if (translated === null) { fail(res, 502, 'Échec de la traduction', 'TRANSLATE_FAILED'); return; }

    const norm = (s: string) => s.replace(/\s+/g, ' ').trim().toLowerCase();
    ok(res, {
      translated,
      source_language: sourceLanguageRaw || 'auto',
      target_language: targetLanguage,
      was_translated: norm(translated) !== norm(text),
    });
  } catch (e: any) {
    logger.error(`[ai/translate] ${e?.message}`);
    fail(res, 500, 'Erreur de traduction', 'TRANSLATE_ERROR');
  }
});

export default router;
