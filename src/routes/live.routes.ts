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
import { issueLiveToken, currentLiveProvider } from '../services/liveToken.service.js';

const router = Router();

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
      .from('live_streams').select('id, vendor_user_id, channel').eq('id', streamId).maybeSingle();
    if (!stream) return fail(res, 404, 'Live introuvable');
    if ((stream as any).vendor_user_id !== userId) return fail(res, 403, 'Réservé au vendeur hôte');

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

// ── GET /streams/live (public) — lives en cours ─────────────────────────────
router.get('/streams/live', async (req, res: Response) => {
  try {
    const country = typeof req.query.country === 'string' ? req.query.country : null;
    let q = supabaseAdmin
      .from('live_streams')
      .select('id, title, vendor_id, vendor_kind, country_code, channel, thumbnail_url, viewer_count, started_at, vendors(business_name)')
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
    const limit = Math.min(Math.max(parseInt(String(req.query.limit || '12'), 10) || 12, 1), 30);
    let q = supabaseAdmin
      .from('live_streams')
      .select('id, title, vendor_id, vendor_kind, country_code, thumbnail_url, replay_url, replay_expires_at, peak_viewer_count, started_at, ended_at, vendors(business_name)')
      .eq('status', 'ended')
      .not('replay_url', 'is', null)
      .gt('replay_expires_at', new Date().toISOString())
      .order('ended_at', { ascending: false })
      .limit(limit);
    if (country) q = q.eq('country_code', country);
    if (before) q = q.lt('ended_at', before);
    const { data, error } = await q;
    if (error) return fail(res, 400, error.message);

    const replays = (data || []).map((s: any) => ({
      id: s.id, title: s.title, vendorId: s.vendor_id,
      vendorName: s.vendors?.business_name || null,
      vendorKind: s.vendor_kind, countryCode: s.country_code,
      thumbnailUrl: s.thumbnail_url, replayUrl: s.replay_url,
      replayExpiresAt: s.replay_expires_at, peakViewerCount: s.peak_viewer_count,
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
    if (error) return fail(res, 400, error.message);

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
    return ok(res, { recorded: true, viewerCount });
  } catch (e: any) {
    logger.error(`[live/events] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

export default router;
