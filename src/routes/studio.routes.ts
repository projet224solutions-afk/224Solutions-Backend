/**
 * 🎨 STUDIO — routes des modèles téléversés.
 * GET /api/studio/templates/:id/download — PROXY de téléchargement : le navigateur ne
 * fetch JAMAIS l'URL GCS directement (CORS bucket → échec silencieux de « Réutiliser »).
 * Le serveur vérifie l'OWNERSHIP (403 pour autrui), récupère le fichier côté serveur
 * (GCS public URL ou bucket Supabase privé via service_role) et le STREAME au client
 * avec les bons headers. Marche en local ET en prod, quel que soit le storage.
 */
import { Router, Response } from 'express';
import { Readable } from 'node:stream';
import { verifyJWT, AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { routeRateLimit } from '../middlewares/routeRateLimiter.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { fail } from '../utils/apiResponse.js';

const router = Router();

// Téléchargements de modèles : 120 / heure / utilisateur (large pour l'usage réel).
const downloadRateLimit = routeRateLimit({
  maxRequests: Number(process.env.STUDIO_TPL_DL_HOURLY_LIMIT || 120),
  windowSeconds: 3600,
  keyPrefix: 'studio-tpl-dl', perUser: true,
});

router.get('/templates/:id/download', verifyJWT, downloadRateLimit, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const id = String(req.params.id || '');
    if (!/^[0-9a-f-]{36}$/i.test(id)) return fail(res, 400, 'Identifiant invalide', 'INVALID_ID');

    const { data: tpl, error } = await supabaseAdmin
      .from('provider_uploaded_templates')
      .select('id, provider_user_id, name, file_url, mime_type, object_path, storage_provider, storage_bucket')
      .eq('id', id)
      .maybeSingle();
    if (error) return fail(res, 500, 'Lecture du modèle impossible', 'DB_ERROR');
    if (!tpl) return fail(res, 404, 'Modèle introuvable', 'NOT_FOUND');
    // 🔒 OWNERSHIP : un prestataire ne télécharge JAMAIS le modèle d'un autre.
    if (tpl.provider_user_id !== req.user!.id) return fail(res, 403, 'Accès refusé', 'FORBIDDEN');

    const filename = encodeURIComponent(tpl.name || 'modele');
    const contentType = tpl.mime_type || 'application/octet-stream';

    // Fallback Supabase (bucket PRIVÉ studio-templates ou legacy) → download service_role.
    if (tpl.storage_provider === 'supabase' && tpl.storage_bucket && tpl.object_path) {
      const { data: blob, error: dlErr } = await supabaseAdmin.storage
        .from(tpl.storage_bucket).download(tpl.object_path);
      if (dlErr || !blob) {
        logger.warn(`[studio] download supabase KO: ${dlErr?.message}`);
        return fail(res, 502, 'Fichier indisponible sur le stockage', 'STORAGE_UNAVAILABLE');
      }
      res.setHeader('Content-Type', contentType);
      res.setHeader('Content-Disposition', `attachment; filename*=UTF-8''${filename}`);
      res.send(Buffer.from(await blob.arrayBuffer()));
      return;
    }

    // GCS (URL publique) : le SERVEUR la lit (pas de CORS serveur→GCS) et streame.
    const upstream = await fetch(tpl.file_url);
    if (!upstream.ok || !upstream.body) {
      logger.warn(`[studio] download gcs KO: HTTP ${upstream.status} ${tpl.file_url.slice(0, 80)}`);
      return fail(res, 502, 'Fichier indisponible sur le stockage', 'STORAGE_UNAVAILABLE');
    }
    res.setHeader('Content-Type', upstream.headers.get('content-type') || contentType);
    res.setHeader('Content-Disposition', `attachment; filename*=UTF-8''${filename}`);
    Readable.fromWeb(upstream.body as any).pipe(res);
  } catch (e: any) {
    logger.error(`[studio] download error: ${e?.message}`);
    return fail(res, 500, 'Téléchargement du modèle impossible', 'DOWNLOAD_FAILED');
  }
});

export default router;
