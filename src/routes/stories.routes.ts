/**
 * 📸 STORIES VENDEUR 24h — routes /api/v2/stories (contrat {success,data} via ok()/fail()).
 *
 * Écritures 100% BACKEND (service_role) : la RLS de vendor_stories n'autorise AUCUN
 * INSERT/UPDATE/DELETE client, donc le garde media_url ci-dessous est la seule porte
 * d'entrée (anti-SSRF / anti-pixel de tracking re-servi aux spectateurs).
 * Compteur de vues via RPC increment_story_view(story_id, viewer_id) — viewer_id passé
 * EXPLICITEMENT (auth.uid() = NULL sous service_role).
 */

import { Router, type Response } from 'express';
import { supabaseAdmin } from '../config/supabase.js';
import { env } from '../config/env.js';
import { logger } from '../config/logger.js';
import { ok, fail } from '../utils/apiResponse.js';
import { verifyJWT, type AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { getBucketName } from '../services/gcs.service.js';

const router = Router();

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_STORY_MS = 60_000; // durée max d'une story vidéo (borne serveur, valeur client non fiable)

/**
 * Le média d'une story est TOUJOURS uploadé sur notre stockage. On borne media_url
 * (et thumbnail_url) au bucket GCS attendu OU à l'hôte EXACT du Supabase Storage du
 * projet (fallback dev de useStorageUpload). Égalité stricte du hostname — jamais un
 * wildcard *.supabase.co (sinon un tiers hébergerait le pixel sur son propre projet).
 */
function isAllowedMediaUrl(raw: string): boolean {
  if (typeof raw !== 'string' || raw.length > 2048) return false;
  let u: URL;
  try { u = new URL(raw); } catch { return false; }
  if (u.protocol !== 'https:') return false;
  const bucket = getBucketName();
  if (u.hostname === `${bucket}.storage.googleapis.com`) return true;
  if (u.hostname === 'storage.googleapis.com' && u.pathname.startsWith(`/${bucket}/`)) return true;
  try {
    if (u.hostname === new URL(env.SUPABASE_URL).hostname) return true;
  } catch { /* SUPABASE_URL malformée — on refuse */ }
  return false;
}

/** Récupère le vendeur (id + pays + avatar) dont le user courant est propriétaire. */
async function getOwnedVendor(userId: string) {
  const { data } = await supabaseAdmin
    .from('vendors')
    .select('id, user_id, seller_country_code, country')
    .eq('user_id', userId)
    .maybeSingle();
  return data as { id: string; user_id: string; seller_country_code: string | null; country: string | null } | null;
}

// ── POST /stories (vendeur) — publie une story ──────────────────────────────
router.post('/', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const { live_stream_id, media_url, media_type, thumbnail_url, caption, duration_ms } = req.body || {};

    const vendor = await getOwnedVendor(userId);
    if (!vendor) return fail(res, 403, 'Réservé aux vendeurs', 'VENDOR_REQUIRED');

    // ── Chemin PRINCIPAL : partager un REPLAY en story ──────────────────────
    // Le média est DÉRIVÉ du replay (côté serveur, source de vérité) après vérification
    // que le live appartient au vendeur et possède bien un replay.
    if (live_stream_id) {
      if (!UUID_RE.test(String(live_stream_id))) return fail(res, 400, 'live_stream_id invalide');
      const { data: live } = await supabaseAdmin
        .from('live_streams')
        .select('id, vendor_user_id, status, replay_url, thumbnail_url')
        .eq('id', live_stream_id).maybeSingle();
      const l = live as any;
      if (!l) return fail(res, 404, 'Live introuvable');
      if (l.vendor_user_id !== userId) return fail(res, 403, 'Réservé au propriétaire du live');
      if (l.status !== 'ended' || !l.replay_url) return fail(res, 400, 'Ce live n\'a pas de replay');

      const { data, error } = await supabaseAdmin
        .from('vendor_stories')
        .insert({
          vendor_id: vendor.id,
          vendor_user_id: userId,
          live_stream_id: l.id,
          media_url: l.replay_url,
          media_type: 'video',
          thumbnail_url: l.thumbnail_url || null,
          caption: typeof caption === 'string' ? caption.slice(0, 300) : null,
          duration_ms: null,
          country_code: vendor.seller_country_code || vendor.country || null,
        })
        .select('id').maybeSingle();
      if (error) return fail(res, 400, error.message);
      return ok(res, { storyId: (data as any)?.id });
    }

    // ── Chemin SECONDAIRE : média libre (upload) ────────────────────────────
    if (media_type !== 'image' && media_type !== 'video') return fail(res, 400, 'media_type invalide');
    if (typeof media_url !== 'string' || !isAllowedMediaUrl(media_url)) {
      return fail(res, 400, 'media_url non autorisée');
    }
    if (thumbnail_url != null && (typeof thumbnail_url !== 'string' || !isAllowedMediaUrl(thumbnail_url))) {
      return fail(res, 400, 'thumbnail_url non autorisée');
    }

    // duration_ms borné côté serveur (valeur client non fiable).
    let dur: number | null = null;
    if (media_type === 'video' && Number.isFinite(Number(duration_ms))) {
      dur = Math.min(Math.max(Math.round(Number(duration_ms)), 0), MAX_STORY_MS);
    }

    const { data, error } = await supabaseAdmin
      .from('vendor_stories')
      .insert({
        vendor_id: vendor.id,
        vendor_user_id: userId,
        media_url,
        media_type,
        thumbnail_url: typeof thumbnail_url === 'string' ? thumbnail_url : null,
        caption: typeof caption === 'string' ? caption.slice(0, 300) : null,
        duration_ms: dur,
        country_code: vendor.seller_country_code || vendor.country || null,
        // expires_at laissé au DEFAULT DB (+24h) — jamais depuis le client.
      })
      .select('id')
      .maybeSingle();
    if (error) return fail(res, 400, error.message);
    return ok(res, { storyId: (data as any)?.id });
  } catch (e: any) {
    logger.error(`[stories/create] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// ── GET /stories/active (public) — vendeurs ayant ≥1 story active ────────────
router.get('/active', async (_req, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin
      .from('vendor_stories')
      .select('id, vendor_id, created_at, vendors(business_name, logo_url)')
      .gt('expires_at', new Date().toISOString())
      .order('created_at', { ascending: false })
      .limit(300);
    if (error) return fail(res, 400, error.message);

    // Agrégation par vendeur (une entrée par boutique, la plus récente en tête).
    const byVendor: Record<string, { vendorId: string; vendorName: string | null; avatarUrl: string | null; storyCount: number; latestAt: string }> = {};
    for (const s of (data || []) as any[]) {
      const vid = s.vendor_id;
      if (!byVendor[vid]) {
        byVendor[vid] = {
          vendorId: vid,
          vendorName: s.vendors?.business_name || null,
          avatarUrl: s.vendors?.logo_url || null,
          storyCount: 0,
          latestAt: s.created_at,
        };
      }
      byVendor[vid].storyCount += 1;
    }
    const vendors = Object.values(byVendor).sort((a, b) => (a.latestAt < b.latestAt ? 1 : -1));
    return ok(res, { vendors });
  } catch (e: any) {
    logger.error(`[stories/active] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// ── GET /stories/vendor/:vendorId (public) — stories actives d'un vendeur ────
router.get('/vendor/:vendorId', async (req, res: Response) => {
  try {
    const vendorId = req.params.vendorId;
    if (!UUID_RE.test(vendorId)) return fail(res, 400, 'vendorId invalide');
    const { data, error } = await supabaseAdmin
      .from('vendor_stories')
      .select('id, live_stream_id, media_url, media_type, thumbnail_url, caption, duration_ms, created_at')
      .eq('vendor_id', vendorId)
      .gt('expires_at', new Date().toISOString())
      .order('created_at', { ascending: true }); // ordre chronologique pour la visionneuse
    if (error) return fail(res, 400, error.message);
    const stories = (data || []).map((s: any) => ({
      id: s.id, liveStreamId: s.live_stream_id || null,
      mediaUrl: s.media_url, mediaType: s.media_type,
      thumbnailUrl: s.thumbnail_url, caption: s.caption,
      durationMs: s.duration_ms, createdAt: s.created_at,
    }));
    return ok(res, { stories });
  } catch (e: any) {
    logger.error(`[stories/vendor] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// ── POST /stories/:id/view (auth) — enregistre une vue (best-effort) ─────────
router.post('/:id/view', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const storyId = req.params.id;
    if (!UUID_RE.test(storyId)) return fail(res, 400, 'id invalide');
    await supabaseAdmin.rpc('increment_story_view', { p_story_id: storyId, p_viewer_id: req.user!.id });
    return ok(res, { recorded: true });
  } catch (e: any) {
    logger.error(`[stories/view] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// ── DELETE /stories/:id (vendeur propriétaire) ──────────────────────────────
router.delete('/:id', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const storyId = req.params.id;
    if (!UUID_RE.test(storyId)) return fail(res, 400, 'id invalide');
    const { data: story } = await supabaseAdmin
      .from('vendor_stories').select('vendor_user_id').eq('id', storyId).maybeSingle();
    if (!story) return fail(res, 404, 'Story introuvable');
    if ((story as any).vendor_user_id !== req.user!.id) return fail(res, 403, 'Non autorisé');
    const { error } = await supabaseAdmin.from('vendor_stories').delete().eq('id', storyId);
    if (error) return fail(res, 400, error.message);
    return ok(res, { deleted: true });
  } catch (e: any) {
    logger.error(`[stories/delete] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

export default router;
