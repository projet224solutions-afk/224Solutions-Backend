/**
 * 🎥 LIVE SHOPPING — routes /api/v2/live (contrat {success,data} via ok()/fail()).
 *
 * Transport vidéo NEUTRE : le token est émis par issueLiveToken() (agora aujourd'hui,
 * livekit demain) ; ces routes ne connaissent jamais Agora directement. Écritures d'état
 * (start/end/viewers) via RPC SECURITY DEFINER (host revérifié dans la fonction).
 */

import { Router, type Response } from 'express';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { ok, fail } from '../utils/apiResponse.js';
import { verifyJWT, type AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { idempotencyGuard } from '../middlewares/idempotency.middleware.js';
import { issueLiveToken, currentLiveProvider } from '../services/liveToken.service.js';
import { uuidToNumericUid } from '../services/agoraToken.js';
import { getBucketName, loadServiceAccount, generateSignedUrl } from '../services/gcs.service.js';

const router = Router();

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * La vignette d'un replay est TOUJOURS uploadée sur notre bucket GCS. On borne donc
 * thumbnail_url au bucket attendu (jamais un domaine tiers) : anti-SSRF / anti-pixel de
 * tracking re-servi aux spectateurs. Accepte les deux formes d'URL GCS :
 *   • host-bucket : https://<bucket>.storage.googleapis.com/<path>
 *   • path-bucket : https://storage.googleapis.com/<bucket>/<path>
 */
function isAllowedThumbnailUrl(raw: string): boolean {
  let u: URL;
  try { u = new URL(raw); } catch { return false; }
  if (u.protocol !== 'https:') return false;
  const bucket = getBucketName();
  if (u.hostname === `${bucket}.storage.googleapis.com`) return true;
  if (u.hostname === 'storage.googleapis.com' && u.pathname.startsWith(`/${bucket}/`)) return true;
  // Fallback LÉGITIME de useStorageUpload : quand GCS n'est pas dispo (dev, session, objet
  // non affichable), l'upload retombe sur NOTRE Supabase Storage (objets publics). Sans ceci
  // la vignette était rejetée (400) → thumbnail_url restait NULL → dégradé orange permanent.
  try {
    const sb = process.env.SUPABASE_URL ? new URL(process.env.SUPABASE_URL) : null;
    if (sb && u.hostname === sb.hostname && u.pathname.startsWith('/storage/v1/object/public/')) return true;
  } catch { /* URL SUPABASE_URL invalide → on ignore */ }
  return false;
}

/** Récupère le vendeur (id + pays) dont le user courant est propriétaire. */
async function getOwnedVendor(userId: string) {
  const { data } = await supabaseAdmin
    .from('vendors')
    .select('id, user_id, seller_country_code, country')
    .eq('user_id', userId)
    .maybeSingle();
  return data as { id: string; user_id: string; seller_country_code: string | null; country: string | null } | null;
}

function bearer(req: AuthenticatedRequest): string {
  const h = req.headers.authorization || '';
  return h.toLowerCase().startsWith('bearer ') ? h.slice(7).trim() : '';
}

// ── POST /streams (host) — crée un live 'scheduled' ─────────────────────────
router.post('/streams', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const { title, product_ids, vendor_kind } = req.body || {};
    if (!title || typeof title !== 'string' || !title.trim()) {
      return fail(res, 400, 'Titre du live requis');
    }
    const vendor = await getOwnedVendor(userId);
    if (!vendor) return fail(res, 403, 'Compte vendeur requis pour diffuser en direct', 'VENDOR_REQUIRED');

    const kind = vendor_kind === 'digital' ? 'digital' : 'physical';
    const channel = `live_${vendor.id.replace(/-/g, '').slice(0, 12)}_${Date.now()}`;
    const { data: stream, error } = await supabaseAdmin
      .from('live_streams')
      .insert({
        vendor_id: vendor.id,
        vendor_user_id: userId,
        title: title.trim().slice(0, 140),
        status: 'scheduled',
        vendor_kind: kind,
        country_code: vendor.seller_country_code || vendor.country || null,
        transport: currentLiveProvider(),
        channel,
      })
      .select('id, channel')
      .single();
    if (error || !stream) return fail(res, 400, error?.message || 'Création du live impossible');

    // Produits associés (optionnels) — le premier devient épinglé par défaut.
    if (Array.isArray(product_ids) && product_ids.length > 0) {
      const rows = product_ids.slice(0, 50).map((pid: string, i: number) => ({
        live_stream_id: stream.id, product_id: pid, is_pinned: i === 0, display_order: i,
      }));
      await supabaseAdmin.from('live_stream_products').insert(rows);
    }
    return ok(res, { streamId: stream.id, channel: stream.channel });
  } catch (e: any) {
    logger.error(`[live/streams] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// ── POST /streams/:id/start (host) — passe live + token HOST ────────────────
router.post('/streams/:id/start', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const streamId = req.params.id;
    const { data: stream } = await supabaseAdmin
      .from('live_streams').select('id, vendor_id, vendor_user_id, channel').eq('id', streamId).maybeSingle();
    if (!stream) return fail(res, 404, 'Live introuvable');
    if ((stream as any).vendor_user_id !== userId) return fail(res, 403, 'Réservé au vendeur hôte');

    // Un seul live actif par vendeur : clôturer les AUTRES lives encore `live` de ce vendeur
    // (fantômes d'un onglet fermé sans clôture) AVANT de démarrer celui-ci → plus de doublons.
    await supabaseAdmin
      .from('live_streams')
      .update({ status: 'ended', ended_at: new Date().toISOString() })
      .eq('vendor_id', (stream as any).vendor_id)
      .eq('status', 'live')
      .neq('id', streamId);

    const { error: rpcErr } = await supabaseAdmin.rpc('start_live_stream', { p_stream_id: streamId });
    if (rpcErr) return fail(res, 400, rpcErr.message);

    const provider = currentLiveProvider();
    const issued = await issueLiveToken(provider, (stream as any).channel, 'host', undefined, bearer(req));
    return ok(res, { token: issued.token, channel: issued.channel, provider, uid: issued.uid, appId: issued.appId });
  } catch (e: any) {
    logger.error(`[live/start] ${e?.message}`);
    return fail(res, 500, e?.message || 'Erreur serveur');
  }
});

// ── POST /streams/:id/token (viewer) — token AUDIENCE ───────────────────────
router.post('/streams/:id/token', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const streamId = req.params.id;
    const { data: stream } = await supabaseAdmin
      .from('live_streams').select('id, status, channel').eq('id', streamId).maybeSingle();
    if (!stream) return fail(res, 404, 'Live introuvable');
    if ((stream as any).status !== 'live') return fail(res, 409, 'Ce live n\'est pas en cours', 'STREAM_NOT_LIVE');

    const provider = currentLiveProvider();
    const issued = await issueLiveToken(provider, (stream as any).channel, 'audience', undefined, bearer(req));
    return ok(res, { token: issued.token, channel: issued.channel, provider, uid: issued.uid, appId: issued.appId });
  } catch (e: any) {
    logger.error(`[live/token] ${e?.message}`);
    return fail(res, 500, e?.message || 'Erreur serveur');
  }
});

// ── POST /streams/:id/end (host) — termine + enregistre replay ──────────────
router.post('/streams/:id/end', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const streamId = req.params.id;
    const { replay_url } = req.body || {};
    const { data: stream } = await supabaseAdmin
      .from('live_streams').select('vendor_user_id').eq('id', streamId).maybeSingle();
    if (!stream) return fail(res, 404, 'Live introuvable');
    if ((stream as any).vendor_user_id !== userId) return fail(res, 403, 'Réservé au vendeur hôte');

    const { data, error } = await supabaseAdmin.rpc('end_live_stream', {
      p_stream_id: streamId,
      p_replay_url: typeof replay_url === 'string' && replay_url ? replay_url : null,
    });
    if (error) return fail(res, 400, error.message);
    return ok(res, data);
  } catch (e: any) {
    logger.error(`[live/end] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// ── POST /streams/:id/replay-ready (host) — replay_url arrivé APRÈS la clôture ──
// FIX 7 : l'upload du replay se fait en arrière-plan (résumable). L'URL peut donc arriver
// APRÈS /end (le live est déjà 'ended'). On met à jour replay_url + expiration sans re-clôturer.
// isAllowedThumbnailUrl = « une de NOS URLs de stockage » (GCS bucket OU Supabase) → réutilisée.
router.post('/streams/:id/replay-ready', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const streamId = req.params.id;
    const { replay_url } = req.body || {};
    if (!UUID_RE.test(streamId)) return fail(res, 400, 'Identifiant de live invalide', 'INVALID_STREAM_ID');
    if (typeof replay_url !== 'string' || replay_url.length > 2048 || !isAllowedThumbnailUrl(replay_url)) {
      return fail(res, 400, 'URL de replay invalide', 'INVALID_REPLAY_URL');
    }
    const { data: stream } = await supabaseAdmin
      .from('live_streams').select('vendor_user_id').eq('id', streamId).maybeSingle();
    if (!stream) return fail(res, 404, 'Live introuvable');
    if ((stream as any).vendor_user_id !== userId) return fail(res, 403, 'Réservé au vendeur hôte');

    const expires = new Date(Date.now() + 30 * 24 * 3600 * 1000).toISOString();
    const { error } = await supabaseAdmin
      .from('live_streams')
      .update({ replay_url, replay_expires_at: expires })
      .eq('id', streamId);
    if (error) return fail(res, 400, error.message);
    return ok(res, { streamId, replayUrl: replay_url });
  } catch (e: any) {
    logger.error(`[live/replay-ready] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// ── POST /streams/:id/thumbnail (host) — vignette du replay (best-effort) ───
// Capturée côté client PENDANT le direct puis uploadée (GCS). Aucune action vendeur.
// Host revérifié : seul le vendeur hôte peut écrire la vignette de SON stream.
router.post('/streams/:id/thumbnail', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const streamId = req.params.id;
    const { thumbnail_url } = req.body || {};
    if (!UUID_RE.test(streamId)) return fail(res, 400, 'Identifiant de live invalide', 'INVALID_STREAM_ID');
    // Validation URL : https + longueur bornée + bucket GCS attendu UNIQUEMENT (anti-SSRF/tracking).
    if (typeof thumbnail_url !== 'string' || thumbnail_url.length > 2048 || !isAllowedThumbnailUrl(thumbnail_url)) {
      return fail(res, 400, 'URL de vignette invalide', 'INVALID_THUMBNAIL_URL');
    }
    const { data: stream, error: fetchErr } = await supabaseAdmin
      .from('live_streams').select('vendor_user_id').eq('id', streamId).maybeSingle();
    if (fetchErr) return fail(res, 500, 'Erreur lors de la lecture du live');
    if (!stream) return fail(res, 404, 'Live introuvable');
    if ((stream as any).vendor_user_id !== userId) return fail(res, 403, 'Réservé au vendeur hôte');

    const { error } = await supabaseAdmin
      .from('live_streams')
      .update({ thumbnail_url })
      .eq('id', streamId);
    if (error) return fail(res, 400, error.message);
    return ok(res, { streamId, thumbnailUrl: thumbnail_url });
  } catch (e: any) {
    logger.error(`[live/thumbnail] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// ── POST /streams/:id/products (host) — ajoute / épingle (exclusif) ─────────
router.post('/streams/:id/products', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const streamId = req.params.id;
    const { product_id, pin } = req.body || {};
    if (!product_id || typeof product_id !== 'string') return fail(res, 400, 'product_id requis');
    const { data: stream } = await supabaseAdmin
      .from('live_streams').select('vendor_user_id').eq('id', streamId).maybeSingle();
    if (!stream) return fail(res, 404, 'Live introuvable');
    if ((stream as any).vendor_user_id !== userId) return fail(res, 403, 'Réservé au vendeur hôte');

    if (pin === true) {
      // Épinglage exclusif : on dépingle tout puis on épingle celui-ci.
      await supabaseAdmin.from('live_stream_products').update({ is_pinned: false }).eq('live_stream_id', streamId);
    }
    const { error } = await supabaseAdmin
      .from('live_stream_products')
      .upsert({ live_stream_id: streamId, product_id, is_pinned: pin === true }, { onConflict: 'live_stream_id,product_id' });
    if (error) return fail(res, 400, error.message);
    return ok(res, { streamId, product_id, pinned: pin === true });
  } catch (e: any) {
    logger.error(`[live/products] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// ── DELETE /streams/:id/products/:productId (host) — retire un produit du live ─
router.delete('/streams/:id/products/:productId', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const streamId = req.params.id;
    const productId = req.params.productId;
    if (!UUID_RE.test(streamId) || !UUID_RE.test(productId)) return fail(res, 400, 'params invalides');
    const { data: stream } = await supabaseAdmin
      .from('live_streams').select('vendor_user_id').eq('id', streamId).maybeSingle();
    if (!stream) return fail(res, 404, 'Live introuvable');
    if ((stream as any).vendor_user_id !== userId) return fail(res, 403, 'Réservé au vendeur hôte');
    const { error } = await supabaseAdmin
      .from('live_stream_products').delete()
      .eq('live_stream_id', streamId).eq('product_id', productId);
    if (error) return fail(res, 400, error.message);
    return ok(res, { removed: true });
  } catch (e: any) {
    logger.error(`[live/products-delete] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// ── GET /streams/live (public) — lives en cours ─────────────────────────────
router.get('/streams/live', async (req, res: Response) => {
  try {
    const country = typeof req.query.country === 'string' ? req.query.country : null;
    let q = supabaseAdmin
      .from('live_streams')
      .select('id, title, vendor_id, vendor_kind, country_code, channel, thumbnail_url, viewer_count, total_likes, started_at, vendors(business_name)')
      .eq('status', 'live')
      .order('viewer_count', { ascending: false })
      .limit(50);
    if (country) q = q.eq('country_code', country);
    const { data, error } = await q;
    if (error) return fail(res, 400, error.message);

    // Produit épinglé par live (best-effort, une requête groupée).
    const ids = (data || []).map((s: any) => s.id);
    const pinnedByStream: Record<string, string> = {};
    if (ids.length) {
      const { data: pins } = await supabaseAdmin
        .from('live_stream_products')
        .select('live_stream_id, product_id')
        .in('live_stream_id', ids)
        .eq('is_pinned', true);
      for (const p of (pins || []) as any[]) pinnedByStream[p.live_stream_id] = p.product_id;
    }
    const streams = (data || []).map((s: any) => ({
      id: s.id, title: s.title, vendorId: s.vendor_id,
      vendorName: s.vendors?.business_name || null,
      vendorKind: s.vendor_kind, countryCode: s.country_code,
      thumbnailUrl: s.thumbnail_url, viewerCount: s.viewer_count,
      totalLikes: s.total_likes ?? 0,
      startedAt: s.started_at, pinnedProductId: pinnedByStream[s.id] || null,
    }));
    return ok(res, { streams });
  } catch (e: any) {
    logger.error(`[live/live] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// ── GET /streams/replays (public) — replays non expirés, pagination keyset ──
router.get('/streams/replays', async (req, res: Response) => {
  try {
    const country = typeof req.query.country === 'string' ? req.query.country : null;
    const before = typeof req.query.before === 'string' ? req.query.before : null;
    const vendor = typeof req.query.vendor === 'string' && UUID_RE.test(req.query.vendor) ? req.query.vendor : null;
    const limit = Math.min(Math.max(parseInt(String(req.query.limit || '12'), 10) || 12, 1), 30);
    let q = supabaseAdmin
      .from('live_streams')
      .select('id, title, vendor_id, vendor_kind, country_code, thumbnail_url, replay_url, replay_expires_at, peak_viewer_count, total_likes, started_at, ended_at, vendors(business_name)')
      .eq('status', 'ended')
      .not('replay_url', 'is', null)
      .gt('replay_expires_at', new Date().toISOString())
      .order('ended_at', { ascending: false })
      .limit(limit);
    if (country) q = q.eq('country_code', country);
    if (vendor) q = q.eq('vendor_id', vendor);
    if (before) q = q.lt('ended_at', before);
    const { data, error } = await q;
    if (error) return fail(res, 400, error.message);

    const replays = (data || []).map((s: any) => ({
      id: s.id, title: s.title, vendorId: s.vendor_id,
      vendorName: s.vendors?.business_name || null,
      vendorKind: s.vendor_kind, countryCode: s.country_code,
      thumbnailUrl: s.thumbnail_url, replayUrl: s.replay_url,
      replayExpiresAt: s.replay_expires_at, peakViewerCount: s.peak_viewer_count,
      totalLikes: s.total_likes ?? 0,
      durationSec: s.started_at && s.ended_at
        ? Math.max(0, Math.round((new Date(s.ended_at).getTime() - new Date(s.started_at).getTime()) / 1000))
        : null,
      endedAt: s.ended_at,
    }));
    const nextBefore = replays.length === limit ? replays[replays.length - 1].endedAt : null;
    return ok(res, { replays, nextBefore });
  } catch (e: any) {
    logger.error(`[live/replays] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// ── GET /streams/counts (public) — compteurs par pays (physique/digital) ────
router.get('/streams/counts', async (_req, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin
      .from('live_streams')
      .select('country_code, vendor_kind')
      .eq('status', 'live');
    // Tolérant : tant que la migration live_shopping n'est pas appliquée (table absente),
    // on renvoie des compteurs vides plutôt qu'une erreur (le bouton Live reste sans pastille).
    if (error) return ok(res, { byCountry: [], totalPhysical: 0, totalDigital: 0, total: 0 });

    const map: Record<string, { country_code: string; physical: number; digital: number }> = {};
    let totalPhysical = 0, totalDigital = 0;
    for (const s of (data || []) as any[]) {
      const cc = s.country_code || 'ZZ';
      map[cc] = map[cc] || { country_code: cc, physical: 0, digital: 0 };
      if (s.vendor_kind === 'digital') { map[cc].digital++; totalDigital++; }
      else { map[cc].physical++; totalPhysical++; }
    }
    return ok(res, {
      byCountry: Object.values(map).sort((a, b) => (b.physical + b.digital) - (a.physical + a.digital)),
      totalPhysical, totalDigital, total: totalPhysical + totalDigital,
    });
  } catch (e: any) {
    logger.error(`[live/counts] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// ── GET /streams/:id/replay (public) — un replay pour la page dédiée ─────────
router.get('/streams/:id/replay', async (req, res: Response) => {
  try {
    const streamId = req.params.id;
    if (!UUID_RE.test(streamId)) return fail(res, 400, 'id invalide');
    const { data, error } = await supabaseAdmin
      .from('live_streams')
      .select('id, title, vendor_id, vendor_user_id, vendor_kind, country_code, thumbnail_url, replay_url, replay_expires_at, peak_viewer_count, total_likes, replay_views, started_at, ended_at, status, vendors(business_name, logo_url)')
      .eq('id', streamId).maybeSingle();
    if (error) return fail(res, 400, error.message);
    const s = data as any;
    if (!s || s.status !== 'ended' || !s.replay_url) return fail(res, 404, 'Replay indisponible');
    if (s.replay_expires_at && new Date(s.replay_expires_at).getTime() <= Date.now()) {
      return fail(res, 410, 'Replay expiré');
    }
    return ok(res, {
      id: s.id, title: s.title, vendorId: s.vendor_id, vendorUserId: s.vendor_user_id,
      vendorName: s.vendors?.business_name || null, vendorLogo: s.vendors?.logo_url || null,
      vendorKind: s.vendor_kind, countryCode: s.country_code,
      thumbnailUrl: s.thumbnail_url, replayUrl: s.replay_url, replayExpiresAt: s.replay_expires_at,
      peakViewerCount: s.peak_viewer_count, totalLikes: s.total_likes ?? 0, replayViews: s.replay_views ?? 0,
      durationSec: s.started_at && s.ended_at
        ? Math.max(0, Math.round((new Date(s.ended_at).getTime() - new Date(s.started_at).getTime()) / 1000))
        : null,
      endedAt: s.ended_at,
    });
  } catch (e: any) {
    logger.error(`[live/replay-get] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// ── POST /streams/:id/replay-view (public) — +1 vue (débounce 1/session client) ─
router.post('/streams/:id/replay-view', async (req, res: Response) => {
  try {
    const streamId = req.params.id;
    if (!UUID_RE.test(streamId)) return fail(res, 400, 'id invalide');
    await supabaseAdmin.rpc('increment_replay_view', { p_stream_id: streamId });
    return ok(res, { recorded: true });
  } catch (e: any) {
    logger.error(`[live/replay-view] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

/** Admin/PDG ? (pour la modération des replays) */
async function isAdminOrPdg(userId: string): Promise<boolean> {
  const { data } = await supabaseAdmin.from('profiles').select('role').eq('id', userId).maybeSingle();
  return ['admin', 'pdg', 'ceo'].includes(((data as any)?.role || '').toLowerCase());
}

// ── DELETE /streams/:id/replay — suppression du replay (propriétaire OU PDG) ─
router.delete('/streams/:id/replay', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const streamId = req.params.id;
    if (!UUID_RE.test(streamId)) return fail(res, 400, 'id invalide');
    const { data: stream } = await supabaseAdmin
      .from('live_streams').select('vendor_user_id, replay_url').eq('id', streamId).maybeSingle();
    if (!stream) return fail(res, 404, 'Live introuvable');
    const s = stream as any;
    const isOwner = s.vendor_user_id === userId;
    if (!isOwner && !(await isAdminOrPdg(userId))) return fail(res, 403, 'Non autorisé');

    // Idempotent : si le replay est déjà vidé, on renvoie succès sans rien casser.
    // 1) Purge best-effort du fichier GCS (le fichier orphelin ne bloque jamais l'opération).
    if (s.replay_url) {
      try {
        const sa = loadServiceAccount();
        const marker = `/${getBucketName()}/`;
        const idx = s.replay_url.indexOf(marker);
        const objectPath = idx >= 0 ? decodeURIComponent(s.replay_url.slice(idx + marker.length).split('?')[0]) : null;
        if (sa && objectPath) {
          const url = generateSignedUrl(sa, getBucketName(), objectPath, { method: 'DELETE', expiresInSeconds: 120 });
          const r = await fetch(url, { method: 'DELETE' });
          if (!(r.ok || r.status === 404)) logger.error(`[live/replay-delete] GCS ${streamId}: HTTP ${r.status}`);
        }
      } catch (e: any) { logger.error(`[live/replay-delete] GCS ${streamId}: ${e?.message}`); }
    }

    // 2) Retire les stories liées à ce replay (elles n'ont plus de cible).
    await supabaseAdmin.from('vendor_stories').delete().eq('live_stream_id', streamId);

    // 3) Vide le replay mais GARDE la ligne live_streams (stats : viewers, likes, ventes).
    const { error } = await supabaseAdmin
      .from('live_streams')
      .update({ replay_url: null, replay_expires_at: null, thumbnail_url: null })
      .eq('id', streamId);
    if (error) return fail(res, 400, error.message);
    return ok(res, { deleted: true });
  } catch (e: any) {
    logger.error(`[live/replay-delete] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// ── POST /streams/:id/events — join/leave/purchase/reaction ─────────────────
router.post('/streams/:id/events', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const streamId = req.params.id;
    const { event_type, metadata } = req.body || {};
    const ALLOWED = ['join', 'leave', 'purchase', 'reaction'];
    if (!ALLOWED.includes(event_type)) return fail(res, 400, 'event_type invalide');

    await supabaseAdmin.from('live_stream_events').insert({
      live_stream_id: streamId, user_id: userId, event_type,
      metadata: metadata && typeof metadata === 'object' ? metadata : {},
    });

    let viewerCount: number | undefined;
    if (event_type === 'join' || event_type === 'leave') {
      const { data } = await supabaseAdmin.rpc('adjust_live_viewers', {
        p_stream_id: streamId, p_delta: event_type === 'join' ? 1 : -1,
      });
      viewerCount = (data as any)?.viewer_count;
    }

    // Réaction coeur : le trigger DB a déjà incrémenté total_likes atomiquement,
    // on relit le vrai total pour que le tap du spectateur reflète l'état serveur.
    let totalLikes: number | undefined;
    if (event_type === 'reaction') {
      const { data } = await supabaseAdmin
        .from('live_streams').select('total_likes').eq('id', streamId).maybeSingle();
      totalLikes = (data as any)?.total_likes;
    }
    return ok(res, { recorded: true, viewerCount, totalLikes });
  } catch (e: any) {
    logger.error(`[live/events] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// ════════════════════════════════════════════════════════════════════════════
// FIX 9 — CADEAUX VIRTUELS (monétisation) : catalogue config PDG + envoi atomique wallet.
// ════════════════════════════════════════════════════════════════════════════

// GET /streams/gift-catalog (public) — la grille de cadeaux ACTIFS (montants config PDG).
router.get('/streams/gift-catalog', async (_req, res: Response) => {
  try {
    const { data } = await supabaseAdmin
      .from('live_gift_catalog')
      .select('code, emoji, label, amount, currency')
      .eq('is_active', true)
      .order('sort_order', { ascending: true });
    return ok(res, { gifts: (data as any[]) || [] });
  } catch (e: any) {
    logger.warn(`[live/gift-catalog] ${e?.message}`);
    return fail(res, 500, 'Catalogue cadeaux indisponible');
  }
});

// Taux de commission plateforme sur les cadeaux — CONFIG PDG (pdg_settings), défaut 10%.
async function getGiftCommissionPct(): Promise<number> {
  try {
    const { data } = await supabaseAdmin
      .from('pdg_settings').select('setting_value').eq('setting_key', 'live_gift_commission_percentage').maybeSingle();
    const raw = (data as any)?.setting_value;
    const v = typeof raw === 'object' && raw !== null ? Number(raw.value) : Number(raw);
    if (Number.isFinite(v) && v >= 0 && v <= 100) return v;
  } catch { /* défaut ci-dessous */ }
  return 10;
}

const GIFT_ERR_MAP: Record<string, { status: number; msg: string; code: string }> = {
  INSUFFICIENT_FUNDS: { status: 400, msg: 'Solde insuffisant pour ce cadeau.', code: 'INSUFFICIENT_FUNDS' },
  DONOR_WALLET_NOT_FOUND: { status: 400, msg: 'Aucun portefeuille dans cette devise.', code: 'NO_WALLET' },
  WALLET_BLOCKED: { status: 403, msg: 'Votre portefeuille est bloqué.', code: 'WALLET_BLOCKED' },
  SELF_GIFT: { status: 400, msg: 'Vous ne pouvez pas vous offrir un cadeau.', code: 'SELF_GIFT' },
};

// POST /streams/:id/gift — envoie un cadeau (débit atomique wallet + commission coffre PDG).
// idempotencyGuard (après verifyJWT) dédoublonne les rejeux (double-clic / réseau).
router.post('/streams/:id([0-9a-fA-F-]{36})/gift', verifyJWT, idempotencyGuard, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const streamId = req.params.id;
    const giftCode = String(req.body?.gift_code || '').trim().toLowerCase();
    if (!giftCode) return fail(res, 400, 'gift_code requis', 'GIFT_CODE_REQUIRED');

    // Montant AUTORITATIF = catalogue serveur (jamais un montant du body).
    const { data: gift } = await supabaseAdmin
      .from('live_gift_catalog').select('code, amount, currency, is_active').eq('code', giftCode).maybeSingle();
    if (!gift || !(gift as any).is_active) return fail(res, 400, 'Cadeau inconnu', 'GIFT_UNKNOWN');

    const { data: stream } = await supabaseAdmin
      .from('live_streams').select('vendor_user_id, status').eq('id', streamId).maybeSingle();
    if (!stream) return fail(res, 404, 'Live introuvable');
    const hostId = (stream as any).vendor_user_id as string;
    if (hostId === userId) return fail(res, 400, 'Vous ne pouvez pas vous offrir un cadeau.', 'SELF_GIFT');

    const amount = Number((gift as any).amount);
    const currency = (gift as any).currency || 'GNF';
    const pct = await getGiftCommissionPct();
    const commission = Math.round(amount * (pct / 100));

    const { data, error } = await supabaseAdmin.rpc('process_live_gift', {
      p_donor_id: userId, p_host_id: hostId, p_gift_code: giftCode,
      p_amount: amount, p_commission: commission, p_live_id: streamId, p_currency: currency,
    });
    if (error) {
      const key = String(error.message || '').match(/[A-Z_]{4,}/)?.[0] || '';
      const mapped = GIFT_ERR_MAP[key];
      if (mapped) return fail(res, mapped.status, mapped.msg, mapped.code);
      logger.error(`[live/gift] ${error.message}`);
      return fail(res, 400, "Le cadeau n'a pas pu être envoyé.", 'GIFT_FAILED');
    }

    // Trace d'audit best-effort (pas bloquante) — l'argent est déjà journalisé par la RPC.
    void supabaseAdmin.from('live_stream_events').insert({
      live_stream_id: streamId, user_id: userId, event_type: 'purchase',
      metadata: { kind: 'gift', gift_code: giftCode, amount, commission },
    }).then(undefined, () => { /* best-effort */ });

    return ok(res, { transaction_id: (data as any)?.transaction_id, gift_code: giftCode, amount, currency });
  } catch (e: any) {
    logger.error(`[live/gift] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// ════════════════════════════════════════════════════════════════════════════
// FIX 10 — STICKERS TEXTE DU HOST : le host écrit ses stickers (max 2), persistés pour
// les spectateurs qui rejoignent en cours de live. La diffusion temps réel passe par le
// canal realtime côté client ; ICI on ne fait que persister l'état courant (host-only).
// ════════════════════════════════════════════════════════════════════════════

const STICKER_STYLES = ['teal', 'orange', 'mono', 'gradient'];

// PUT /streams/:id/stickers — remplace l'ensemble des stickers actifs (host uniquement).
router.put('/streams/:id([0-9a-fA-F-]{36})/stickers', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const streamId = req.params.id;
    const { data: stream } = await supabaseAdmin
      .from('live_streams').select('vendor_user_id').eq('id', streamId).maybeSingle();
    if (!stream) return fail(res, 404, 'Live introuvable');
    if ((stream as any).vendor_user_id !== userId) return fail(res, 403, 'Réservé au vendeur hôte');

    const raw = Array.isArray(req.body?.stickers) ? req.body.stickers : [];
    // Validation + normalisation : max 2, texte ≤ 20 car., style whitelisté, x/y ∈ [0,100].
    const stickers = raw.slice(0, 2).map((s: any) => ({
      id: String(s?.id || '').slice(0, 40) || `stk-${Math.abs(Math.round(Number(s?.x) || 0))}-${Math.abs(Math.round(Number(s?.y) || 0))}`,
      text: Array.from(String(s?.text || '')).filter((c) => c >= ' ').join('').trim().slice(0, 20),
      style: STICKER_STYLES.includes(String(s?.style)) ? String(s.style) : 'teal',
      x: Math.min(100, Math.max(0, Number(s?.x) || 0)),
      y: Math.min(100, Math.max(0, Number(s?.y) || 0)),
    })).filter((s: any) => s.text.length > 0);

    const { error } = await supabaseAdmin.from('live_streams').update({ active_stickers: stickers }).eq('id', streamId);
    if (error) return fail(res, 400, error.message);
    return ok(res, { stickers });
  } catch (e: any) {
    logger.error(`[live/stickers] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// ════════════════════════════════════════════════════════════════════════════
// COMMENTAIRES DE REPLAY (persistants, modérés) — distinct du chat live éphémère.
// ════════════════════════════════════════════════════════════════════════════

// GET /streams/:id/comments (public) — commentaires visibles d'un replay.
router.get('/streams/:id/comments', async (req, res: Response) => {
  try {
    const streamId = req.params.id;
    if (!UUID_RE.test(streamId)) return fail(res, 400, 'id invalide');
    const { data, error } = await supabaseAdmin
      .from('live_replay_comments')
      .select('id, user_id, author_name, content, parent_id, is_vendor, created_at')
      .eq('stream_id', streamId).eq('status', 'visible')
      .order('created_at', { ascending: true }).limit(500);
    if (error) return fail(res, 400, error.message);
    const comments = (data || []).map((c: any) => ({
      id: c.id, userId: c.user_id, authorName: c.author_name || null,
      content: c.content, parentId: c.parent_id || null,
      isVendor: c.is_vendor === true, createdAt: c.created_at,
    }));
    return ok(res, { comments });
  } catch (e: any) {
    logger.error(`[live/comments-get] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// POST /streams/:id/comments (auth) — publie un commentaire (rate-limité 5/min).
router.post('/streams/:id/comments', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const streamId = req.params.id;
    if (!UUID_RE.test(streamId)) return fail(res, 400, 'id invalide');
    const content = typeof req.body?.content === 'string' ? req.body.content.trim() : '';
    const parentId = typeof req.body?.parent_id === 'string' && UUID_RE.test(req.body.parent_id) ? req.body.parent_id : null;
    if (!content || content.length > 500) return fail(res, 400, 'Commentaire vide ou trop long');

    const { data: stream } = await supabaseAdmin
      .from('live_streams').select('id, vendor_user_id, status').eq('id', streamId).maybeSingle();
    if (!stream) return fail(res, 404, 'Replay introuvable');
    const vendorUserId = (stream as any).vendor_user_id;

    // Anti-spam : max 5 commentaires / 60 s / utilisateur.
    const since = new Date(Date.now() - 60_000).toISOString();
    const { count } = await supabaseAdmin
      .from('live_replay_comments')
      .select('id', { count: 'exact', head: true })
      .eq('user_id', userId).gt('created_at', since);
    if ((count || 0) >= 5) return fail(res, 429, 'Trop de commentaires, réessayez dans un instant', 'RATE_LIMITED');

    // Nom d'auteur dénormalisé (best-effort) + drapeau vendeur calculé serveur.
    const { data: prof } = await supabaseAdmin
      .from('profiles').select('first_name, last_name, full_name').eq('id', userId).maybeSingle();
    const p = (prof || {}) as any;
    const authorName = (p.full_name || [p.first_name, p.last_name].filter(Boolean).join(' ') || '').trim() || null;
    const isVendor = vendorUserId === userId;

    const { data, error } = await supabaseAdmin
      .from('live_replay_comments')
      .insert({ stream_id: streamId, user_id: userId, author_name: authorName, content, parent_id: parentId, is_vendor: isVendor })
      .select('id, user_id, author_name, content, parent_id, is_vendor, created_at').maybeSingle();
    if (error) return fail(res, 400, error.message);

    // Notifie le vendeur (in-app + email, JAMAIS SMS) — best-effort, non bloquant.
    if (!isVendor && vendorUserId) {
      await supabaseAdmin.from('notifications').insert({
        user_id: vendorUserId,
        title: 'Nouveau commentaire sur votre replay',
        message: content.slice(0, 120),
        type: 'replay_comment',
        read: false,
        metadata: { entity_type: 'live_replay', stream_id: streamId, comment_id: (data as any)?.id },
      }).then(({ error: nErr }) => { if (nErr) logger.error(`[live/comments] notif: ${nErr.message}`); });
    }

    const c = data as any;
    return ok(res, {
      comment: { id: c.id, userId: c.user_id, authorName: c.author_name || null, content: c.content,
        parentId: c.parent_id || null, isVendor: c.is_vendor === true, createdAt: c.created_at },
    });
  } catch (e: any) {
    logger.error(`[live/comments-post] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// DELETE /comments/:id (auth) — auteur, vendeur du replay, ou PDG (soft delete).
router.delete('/comments/:id', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const commentId = req.params.id;
    if (!UUID_RE.test(commentId)) return fail(res, 400, 'id invalide');
    const { data: comment } = await supabaseAdmin
      .from('live_replay_comments').select('id, user_id, stream_id').eq('id', commentId).maybeSingle();
    if (!comment) return fail(res, 404, 'Commentaire introuvable');
    const cm = comment as any;

    let allowed = cm.user_id === userId;
    if (!allowed) {
      const { data: stream } = await supabaseAdmin
        .from('live_streams').select('vendor_user_id').eq('id', cm.stream_id).maybeSingle();
      allowed = (stream as any)?.vendor_user_id === userId || await isAdminOrPdg(userId);
    }
    if (!allowed) return fail(res, 403, 'Non autorisé');

    const { error } = await supabaseAdmin
      .from('live_replay_comments').update({ status: 'removed' }).eq('id', commentId);
    if (error) return fail(res, 400, error.message);
    return ok(res, { deleted: true });
  } catch (e: any) {
    logger.error(`[live/comments-delete] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// ── GET /streams/my-streams (vendeur) — SES lives/replays + agrégats (une requête) ─
router.get('/my-streams', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const limit = Math.min(Math.max(parseInt(String(req.query.limit || '20'), 10) || 20, 1), 50);
    const offset = Math.max(parseInt(String(req.query.offset || '0'), 10) || 0, 0);

    const [{ data: rows, error: e1 }, { data: totalsRows, error: e2 }] = await Promise.all([
      supabaseAdmin.rpc('get_vendor_live_streams', { p_vendor_user_id: userId, p_limit: limit, p_offset: offset }),
      supabaseAdmin.rpc('get_vendor_live_totals', { p_vendor_user_id: userId }),
    ]);
    if (e1) return fail(res, 400, e1.message);
    if (e2) return fail(res, 400, e2.message);

    const streams = ((rows as any[]) || []).map((s) => ({
      id: s.id, title: s.title, status: s.status,
      thumbnailUrl: s.thumbnail_url, replayUrl: s.replay_url, replayExpiresAt: s.replay_expires_at,
      totalLikes: s.total_likes ?? 0, replayViews: s.replay_views ?? 0,
      viewerCount: s.viewer_count ?? 0, peakViewerCount: s.peak_viewer_count ?? 0,
      commentsCount: Number(s.comments_count) || 0, purchasesCount: Number(s.purchases_count) || 0,
      startedAt: s.started_at, endedAt: s.ended_at, createdAt: s.created_at,
    }));
    const t = ((totalsRows as any[]) || [])[0] || {};
    const totals = {
      streamsCount: Number(t.streams_count) || 0,
      totalLikes: Number(t.total_likes) || 0,
      totalReplayViews: Number(t.total_replay_views) || 0,
      totalComments: Number(t.total_comments) || 0,
      totalPurchases: Number(t.total_purchases) || 0,
    };
    return ok(res, { streams, totals });
  } catch (e: any) {
    logger.error(`[live/my-streams] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// ════════════════════════════════════════════════════════════════════════════
// CO-HOST / multi-diffuseur. Autorisation : acteur passé EXPLICITEMENT aux RPC
// (service_role → auth.uid()=NULL) + re-vérif applicative dans la route.
// ════════════════════════════════════════════════════════════════════════════

// POST /streams/:id/cohosts (host) — invite un vendeur à co-diffuser.
router.post('/streams/:id/cohosts', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const streamId = req.params.id;
    const { cohost_vendor_id } = req.body || {};
    if (!UUID_RE.test(streamId) || !UUID_RE.test(String(cohost_vendor_id || ''))) {
      return fail(res, 400, 'Paramètres invalides');
    }
    const { data: stream } = await supabaseAdmin
      .from('live_streams').select('id, vendor_user_id, status').eq('id', streamId).maybeSingle();
    if (!stream) return fail(res, 404, 'Live introuvable');
    if ((stream as any).vendor_user_id !== userId) return fail(res, 403, 'Réservé au vendeur hôte');

    const { data, error } = await supabaseAdmin.rpc('invite_live_cohost', {
      p_stream_id: streamId, p_cohost_vendor_id: cohost_vendor_id, p_actor_user_id: userId,
    });
    if (error) return fail(res, 400, error.message);
    const cohostUserId = (data as any)?.cohost_user_id;
    const cohostId = (data as any)?.cohost_id;

    // Notification durable au co-hôte (deeplink dans metadata, pas de colonne dédiée).
    if (cohostUserId) {
      await supabaseAdmin.from('notifications').insert({
        user_id: cohostUserId,
        title: 'Invitation à co-animer un live',
        message: 'Un vendeur vous invite à diffuser en direct avec lui.',
        type: 'live_cohost',
        read: false,
        metadata: { entity_type: 'live_cohost', cohost_id: cohostId, stream_id: streamId },
      });
    }
    return ok(res, { cohostId });
  } catch (e: any) {
    logger.error(`[live/cohost-invite] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// POST /cohosts/:cohostId/respond (co-hôte) — accepte/refuse SON invitation.
router.post('/cohosts/:cohostId/respond', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const cohostId = req.params.cohostId;
    if (!UUID_RE.test(cohostId)) return fail(res, 400, 'id invalide');
    const accept = req.body?.accept === true;
    const { data, error } = await supabaseAdmin.rpc('respond_live_cohost', {
      p_cohost_id: cohostId, p_accept: accept, p_actor_user_id: req.user!.id,
    });
    if (error) return fail(res, 400, error.message);
    return ok(res, data);
  } catch (e: any) {
    logger.error(`[live/cohost-respond] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// POST /streams/:id/join-request (spectateur VENDEUR) — DEMANDE à rejoindre le live.
router.post('/streams/:id/join-request', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const streamId = req.params.id;
    if (!UUID_RE.test(streamId)) return fail(res, 400, 'id invalide');
    // La RPC vérifie : vendeur avec boutique, live en cours, pas le host, cooldown anti-spam.
    const { data, error } = await supabaseAdmin.rpc('request_join_live', {
      p_stream_id: streamId, p_actor_user_id: userId,
    });
    if (error) return fail(res, 400, error.message);

    // Notification durable au host (en plus du realtime « join-request » côté client).
    const { data: stream } = await supabaseAdmin
      .from('live_streams').select('vendor_user_id').eq('id', streamId).maybeSingle();
    const hostId = (stream as any)?.vendor_user_id;
    if (hostId) {
      await supabaseAdmin.from('notifications').insert({
        user_id: hostId,
        title: 'Demande pour rejoindre votre live',
        message: 'Un vendeur demande à co-animer votre direct.',
        type: 'live_cohost',
        read: false,
        metadata: { entity_type: 'live_join_request', cohost_id: (data as any)?.cohost_id, stream_id: streamId },
      });
    }
    return ok(res, data);
  } catch (e: any) {
    logger.error(`[live/join-request] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// POST /cohosts/:cohostId/respond-request (HOST) — accepte/refuse une demande 'requested'.
router.post('/cohosts/:cohostId/respond-request', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const cohostId = req.params.cohostId;
    if (!UUID_RE.test(cohostId)) return fail(res, 400, 'id invalide');
    const accept = req.body?.accept === true;
    const { data, error } = await supabaseAdmin.rpc('respond_join_request', {
      p_cohost_id: cohostId, p_accept: accept, p_actor_user_id: req.user!.id,
    });
    if (error) return fail(res, 400, error.message);
    return ok(res, data);
  } catch (e: any) {
    logger.error(`[live/respond-join-request] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// GET /streams/:id/join-requests (HOST) — demandes 'requested' en attente de SON live.
router.get('/streams/:id/join-requests', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const streamId = req.params.id;
    if (!UUID_RE.test(streamId)) return fail(res, 400, 'id invalide');
    const { data: stream } = await supabaseAdmin
      .from('live_streams').select('vendor_user_id').eq('id', streamId).maybeSingle();
    if (!stream) return fail(res, 404, 'Live introuvable');
    if ((stream as any).vendor_user_id !== userId) return fail(res, 403, 'Réservé au vendeur hôte');

    const { data, error } = await supabaseAdmin
      .from('live_cohosts')
      .select('id, cohost_vendor_id, requested_at:invited_at, vendors(business_name)')
      .eq('live_stream_id', streamId)
      .eq('status', 'requested')
      .eq('initiated_by', 'guest')
      .order('invited_at', { ascending: true });
    if (error) return fail(res, 400, error.message);
    const requests = (data || []).map((r: any) => ({
      cohostId: r.id, vendorId: r.cohost_vendor_id,
      vendorName: r.vendors?.business_name ?? null, requestedAt: r.requested_at,
    }));
    return ok(res, { requests });
  } catch (e: any) {
    logger.error(`[live/join-requests] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// POST /cohosts/:cohostId/leave (co-hôte OU host) — fin de participation.
router.post('/cohosts/:cohostId/leave', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const cohostId = req.params.cohostId;
    if (!UUID_RE.test(cohostId)) return fail(res, 400, 'id invalide');
    const { data, error } = await supabaseAdmin.rpc('end_live_cohost', {
      p_cohost_id: cohostId, p_actor_user_id: req.user!.id,
    });
    if (error) return fail(res, 400, error.message);
    return ok(res, data);
  } catch (e: any) {
    logger.error(`[live/cohost-leave] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// POST /streams/:id/cohost-token (co-hôte accepté) — token HOST (publisher) pour le
// MÊME channel, avec un uid DISTINCT de l'hôte (garde anti-collision de hash).
router.post('/streams/:id/cohost-token', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const streamId = req.params.id;
    if (!UUID_RE.test(streamId)) return fail(res, 400, 'id invalide');

    const { data: stream } = await supabaseAdmin
      .from('live_streams').select('id, status, channel, vendor_user_id').eq('id', streamId).maybeSingle();
    if (!stream) return fail(res, 404, 'Live introuvable');
    if ((stream as any).status !== 'live') return fail(res, 409, 'Le live n\'est pas en cours');

    // L'appelant doit être un co-hôte ACCEPTÉ de ce live.
    const { data: cohost } = await supabaseAdmin
      .from('live_cohosts').select('id, status')
      .eq('live_stream_id', streamId).eq('cohost_user_id', userId).maybeSingle();
    if (!cohost || !['accepted', 'live'].includes((cohost as any).status)) {
      return fail(res, 403, 'Invitation non acceptée');
    }

    const { error: rpcErr } = await supabaseAdmin.rpc('mark_cohost_live', {
      p_stream_id: streamId, p_actor_user_id: userId,
    });
    if (rpcErr) return fail(res, 400, rpcErr.message);

    // Garde anti-collision d'uid (hash %2147483647) : deux PUBLISHERS avec le même uid
    // casseraient le channel Agora. Si collision avec l'hôte → décalage explicite.
    const hostUid = uuidToNumericUid((stream as any).vendor_user_id);
    let cohostUid = uuidToNumericUid(userId);
    if (cohostUid === hostUid) cohostUid = hostUid === 2147483646 ? hostUid - 1 : hostUid + 1;

    const provider = currentLiveProvider();
    const issued = await issueLiveToken(provider, (stream as any).channel, 'host', String(cohostUid), bearer(req));
    return ok(res, { token: issued.token, channel: issued.channel, provider, uid: issued.uid, appId: issued.appId, hostUid: String(hostUid) });
  } catch (e: any) {
    logger.error(`[live/cohost-token] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// GET /streams/:id/cohosts (public) — co-hôtes EN DIRECT (uid + nom, jamais l'uuid brut).
router.get('/streams/:id/cohosts', async (req, res: Response) => {
  try {
    const streamId = req.params.id;
    if (!UUID_RE.test(streamId)) return fail(res, 400, 'id invalide');
    const { data: stream } = await supabaseAdmin
      .from('live_streams').select('vendor_user_id').eq('id', streamId).maybeSingle();
    const hostUid = stream ? String(uuidToNumericUid((stream as any).vendor_user_id)) : null;

    const { data, error } = await supabaseAdmin
      .from('live_cohosts')
      .select('id, cohost_user_id, cohost_vendor_id, status, vendors:cohost_vendor_id(business_name)')
      .eq('live_stream_id', streamId).eq('status', 'live');
    if (error) return fail(res, 400, error.message);
    // `cohostId` exposé pour permettre au HOST de révoquer (FIX 4). end_live_cohost gate par
    // acteur (owner→revoked / cohost→left / autre→refus) : exposer l'id reste sûr.
    const cohosts = (data || []).map((c: any) => ({
      cohostId: c.id,
      uid: String(uuidToNumericUid(c.cohost_user_id)),
      vendorId: c.cohost_vendor_id,
      vendorName: c.vendors?.business_name || null,
    }));
    return ok(res, { hostUid, cohosts });
  } catch (e: any) {
    logger.error(`[live/cohosts] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

export default router;
