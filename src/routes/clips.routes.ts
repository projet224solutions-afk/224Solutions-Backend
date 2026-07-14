/**
 * 🎬 STUDIO CLIPS — création/suivi/suppression de clips promo depuis un replay live.
 * Auth : verifyJWT. Le vendeur est résolu par req.user.id (jamais un vendor_id fourni par le client).
 * Validation + quota + insert : RPC atomique create_clip_job. Le worker ffmpeg (jobs/clipWorker)
 * traite les jobs rendered_on='server'. Les jobs 'device' sont finalisés par le client (Chantier B).
 */
import { Router, Response } from 'express';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { authRateLimit } from '../middlewares/routeRateLimiter.js';
import { loadServiceAccount, getBucketName, generateSignedUrl } from '../services/gcs.service.js';

const router = Router();

/** Résout le vendeur du user authentifié (ou null). */
async function getVendorForUser(userId: string): Promise<{ id: string } | null> {
  const { data } = await supabaseAdmin.from('vendors').select('id').eq('user_id', userId).maybeSingle();
  return (data as any) || null;
}

/** Mappe une erreur RPC create_clip_job → {code, message FR}. */
function mapClipError(msg: string): { code: number; error: string } {
  const m = String(msg || '');
  if (m.includes('STREAM_INTROUVABLE')) return { code: 404, error: "Ce live/replay est introuvable ou ne vous appartient pas." };
  if (m.includes('REPLAY_INDISPONIBLE')) return { code: 409, error: "Le replay de ce live n'est pas encore disponible." };
  if (m.includes('SEGMENTS_CHEVAUCHENT')) return { code: 400, error: "Les segments sélectionnés se chevauchent." };
  if (m.includes('SEGMENT_INVALIDE') || m.includes('SEGMENTS_INVALIDES')) return { code: 400, error: "Sélection de segments invalide (1 à 3 plages, début < fin)." };
  if (m.includes('DUREE_DEPASSEE')) return { code: 400, error: "La durée totale dépasse la limite (5 minutes)." };
  if (m.includes('QUOTA_ATTEINT')) return { code: 429, error: "Quota de clips du jour atteint. Réessayez demain." };
  if (m.includes('RENDERED_ON_INVALIDE')) return { code: 400, error: "Mode de rendu invalide." };
  return { code: 500, error: "Création du clip impossible." };
}

/** Extrait le chemin objet GCS d'une URL publique (https://<bucket>.storage.googleapis.com/<path>). */
function gcsObjectPath(url: string, bucket: string): string | null {
  try {
    const u = new URL(url);
    if (!u.hostname.includes(`${bucket}.storage.googleapis.com`) && !u.pathname.startsWith(`/${bucket}/`)) {
      // Autre forme : storage.googleapis.com/<bucket>/<path>
      if (u.pathname.startsWith(`/${bucket}/`)) return decodeURIComponent(u.pathname.slice(bucket.length + 2));
    }
    if (u.hostname.startsWith(`${bucket}.`)) return decodeURIComponent(u.pathname.replace(/^\//, ''));
    if (u.pathname.startsWith(`/${bucket}/`)) return decodeURIComponent(u.pathname.slice(bucket.length + 2));
    return null;
  } catch { return null; }
}

/** Supprime best-effort les fichiers GCS d'un clip (via URL signée DELETE). */
async function deleteClipFiles(urls: (string | null | undefined)[]): Promise<void> {
  const sa = loadServiceAccount();
  const bucket = getBucketName();
  if (!sa || !bucket) return;
  for (const url of urls) {
    if (!url) continue;
    const path = gcsObjectPath(url, bucket);
    if (!path) continue;
    try {
      const signed = generateSignedUrl(sa, bucket, path, { method: 'DELETE', expiresInSeconds: 120 });
      const resp = await fetch(signed, { method: 'DELETE' });
      if (!(resp.ok || resp.status === 404)) logger.error(`[clips] delete GCS ${path}: HTTP ${resp.status}`);
    } catch (e: any) { logger.error(`[clips] delete GCS ${path}: ${e?.message}`); }
  }
}

// ── GET /api/clips/music : bibliothèque active (AVANT /:id) ──
router.get('/music', verifyJWT, async (_req: AuthenticatedRequest, res: Response): Promise<void> => {
  const { data, error } = await supabaseAdmin.from('clip_music_tracks')
    .select('id, title, mood, duration_s, url, license_note')
    .eq('is_active', true).order('mood', { ascending: true });
  if (error) { res.status(500).json({ success: false, error: 'Bibliothèque indisponible' }); return; }
  res.json({ success: true, data: data || [] });
});

// ── GET /api/clips/mine : liste des clips du vendeur ──
router.get('/mine', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const vendor = await getVendorForUser(req.user!.id);
  if (!vendor) { res.status(403).json({ success: false, error: 'Compte vendeur introuvable' }); return; }
  const { data, error } = await supabaseAdmin.from('live_clips')
    .select('id, stream_id, title, status, rendered_on, progress, segments, overlay, music_track_id, output_url, output_vertical_url, thumbnail_url, duration_s, size_bytes, error, created_at')
    .eq('vendor_id', vendor.id).order('created_at', { ascending: false }).limit(50);
  if (error) { res.status(500).json({ success: false, error: 'Liste indisponible' }); return; }
  res.json({ success: true, data: data || [] });
});

// ── POST /api/clips : créer un job (validation + quota via RPC) ──
router.post('/', verifyJWT, authRateLimit, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const vendor = await getVendorForUser(req.user!.id);
  if (!vendor) { res.status(403).json({ success: false, error: 'Compte vendeur introuvable' }); return; }

  const b = req.body || {};
  const idem = String(req.headers['idempotency-key'] || b.idempotency_key || '') || null;
  const { data, error } = await supabaseAdmin.rpc('create_clip_job', {
    p_vendor_id: vendor.id,
    p_stream_id: b.stream_id,
    p_title: b.title ?? null,
    p_segments: b.segments ?? [],
    p_overlay: b.overlay ?? {},
    p_music_track_id: b.music_track_id ?? null,
    p_cover_time_s: b.cover_time_s ?? null,
    p_rendered_on: b.rendered_on === 'device' ? 'device' : 'server',
    p_idempotency_key: idem,
  });
  if (error) { const e = mapClipError(error.message); res.status(e.code).json({ success: false, error: e.error }); return; }
  res.json({ success: true, data: { id: data } });
});

// ── GET /api/clips/:id : détail + progress ──
router.get('/:id', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const vendor = await getVendorForUser(req.user!.id);
  if (!vendor) { res.status(403).json({ success: false, error: 'Compte vendeur introuvable' }); return; }
  const { data, error } = await supabaseAdmin.from('live_clips')
    .select('*').eq('id', req.params.id).eq('vendor_id', vendor.id).maybeSingle();
  if (error || !data) { res.status(404).json({ success: false, error: 'Clip introuvable' }); return; }
  res.json({ success: true, data });
});

// ── DELETE /api/clips/:id : supprime (queued/failed/ready) + fichiers GCS ──
router.delete('/:id', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const vendor = await getVendorForUser(req.user!.id);
  if (!vendor) { res.status(403).json({ success: false, error: 'Compte vendeur introuvable' }); return; }
  const { data: clip } = await supabaseAdmin.from('live_clips')
    .select('id, status, output_url, output_vertical_url, thumbnail_url')
    .eq('id', req.params.id).eq('vendor_id', vendor.id).maybeSingle();
  if (!clip) { res.status(404).json({ success: false, error: 'Clip introuvable' }); return; }
  if ((clip as any).status === 'processing') { res.status(409).json({ success: false, error: 'Clip en cours de génération — réessayez ensuite.' }); return; }

  await deleteClipFiles([(clip as any).output_url, (clip as any).output_vertical_url, (clip as any).thumbnail_url]);
  const { error } = await supabaseAdmin.from('live_clips').delete().eq('id', (clip as any).id).eq('vendor_id', vendor.id);
  if (error) { res.status(500).json({ success: false, error: 'Suppression impossible' }); return; }
  res.json({ success: true, data: { deleted: true } });
});

export default router;
