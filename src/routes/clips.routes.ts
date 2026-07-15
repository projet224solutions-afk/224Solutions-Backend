/**
 * 🎬 STUDIO CLIPS — création/suivi/suppression de clips promo depuis un replay live.
 * Auth : verifyJWT. Le vendeur est résolu par req.user.id (jamais un vendor_id fourni par le client).
 * Validation + quota + insert : RPC atomique create_clip_job. Le worker ffmpeg (jobs/clipWorker)
 * traite les jobs rendered_on='server'. Les jobs 'device' sont finalisés par le client (Chantier B).
 */
import { Router, Response } from 'express';
import crypto from 'crypto';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { authRateLimit } from '../middlewares/routeRateLimiter.js';
import { CLIP_BUCKET } from '../jobs/clipWorker.js';

const router = Router();

/** Résout le vendeur du user authentifié (ou null). */
async function getVendorForUser(userId: string): Promise<{ id: string } | null> {
  const { data } = await supabaseAdmin.from('vendors').select('id').eq('user_id', userId).maybeSingle();
  return (data as any) || null;
}

/** PDG/admin ? (biblio musicale + quotas). */
async function isPdg(userId: string): Promise<boolean> {
  const { data } = await supabaseAdmin.from('pdg_management').select('id').eq('user_id', userId).eq('is_active', true).maybeSingle();
  if (data) return true;
  const { data: prof } = await supabaseAdmin.from('profiles').select('role').eq('id', userId).maybeSingle();
  return ['pdg', 'admin', 'ceo'].includes((((prof as any)?.role) || '').toLowerCase());
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

/** Extrait le chemin objet Supabase d'une URL publique (.../object/public/<bucket>/<path>). */
function storagePath(url: string): string | null {
  try {
    const marker = `/object/public/${CLIP_BUCKET}/`;
    const i = url.indexOf(marker);
    return i >= 0 ? decodeURIComponent(url.slice(i + marker.length).split('?')[0]) : null;
  } catch { return null; }
}

/** Supprime best-effort les fichiers Supabase Storage d'un clip. */
async function deleteClipFiles(urls: (string | null | undefined)[]): Promise<void> {
  const paths = urls.map((u) => (u ? storagePath(u) : null)).filter(Boolean) as string[];
  if (!paths.length) return;
  const { error } = await supabaseAdmin.storage.from(CLIP_BUCKET).remove(paths);
  if (error) logger.error(`[clips] delete storage: ${error.message}`);
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

// ══════════ ADMIN PDG (Chantier D) : bibliothèque musicale + quotas ══════════

// GET /api/clips/admin/config — lecture des quotas.
router.get('/admin/config', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  if (!(await isPdg(req.user!.id))) { res.status(403).json({ success: false, error: 'PDG uniquement' }); return; }
  const { data } = await supabaseAdmin.from('clip_config').select('*').eq('id', true).maybeSingle();
  res.json({ success: true, data });
});

// PATCH /api/clips/admin/config — met à jour les quotas.
router.patch('/admin/config', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  if (!(await isPdg(req.user!.id))) { res.status(403).json({ success: false, error: 'PDG uniquement' }); return; }
  const b = req.body || {};
  const upd: Record<string, any> = { updated_at: new Date().toISOString() };
  if (b.max_clips_per_vendor_per_day != null) upd.max_clips_per_vendor_per_day = Math.max(1, parseInt(b.max_clips_per_vendor_per_day, 10) || 5);
  if (b.max_clip_duration_s != null) upd.max_clip_duration_s = Math.min(900, Math.max(15, parseInt(b.max_clip_duration_s, 10) || 300));
  if (b.clip_output_height != null && [480, 720, 1080].includes(Number(b.clip_output_height))) upd.clip_output_height = Number(b.clip_output_height);
  const { error } = await supabaseAdmin.from('clip_config').update(upd).eq('id', true);
  if (error) { res.status(500).json({ success: false, error: 'Mise à jour impossible' }); return; }
  res.json({ success: true, data: { updated: true } });
});

// GET /api/clips/admin/music — TOUTES les pistes (actives + inactives).
router.get('/admin/music', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  if (!(await isPdg(req.user!.id))) { res.status(403).json({ success: false, error: 'PDG uniquement' }); return; }
  const { data } = await supabaseAdmin.from('clip_music_tracks').select('*').order('created_at', { ascending: false });
  res.json({ success: true, data: data || [] });
});

// POST /api/clips/admin/music/upload-url — URL signée PUT pour déposer un fichier musique dans GCS.
router.post('/admin/music/upload-url', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  if (!(await isPdg(req.user!.id))) { res.status(403).json({ success: false, error: 'PDG uniquement' }); return; }
  const ct = String(req.body?.content_type || 'audio/mpeg');
  const ext = ct.includes('mp4') || ct.includes('m4a') ? 'm4a' : ct.includes('wav') ? 'wav' : 'mp3';
  const objectPath = `clips-music/${crypto.randomUUID()}.${ext}`;
  const { data: signed, error: sErr } = await supabaseAdmin.storage.from(CLIP_BUCKET).createSignedUploadUrl(objectPath);
  if (sErr || !signed) { res.status(500).json({ success: false, error: 'URL indisponible' }); return; }
  const publicUrl = supabaseAdmin.storage.from(CLIP_BUCKET).getPublicUrl(objectPath).data.publicUrl;
  res.json({ success: true, data: { path: objectPath, token: signed.token, content_type: ct, public_url: publicUrl } });
});

// POST /api/clips/admin/music — crée une piste (après upload : url publique fournie).
router.post('/admin/music', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  if (!(await isPdg(req.user!.id))) { res.status(403).json({ success: false, error: 'PDG uniquement' }); return; }
  const b = req.body || {};
  if (!b.title || !b.url) { res.status(400).json({ success: false, error: 'Titre et URL requis' }); return; }
  const mood = ['énergique', 'chill', 'afro', 'premium'].includes(b.mood) ? b.mood : 'premium';
  const { data, error } = await supabaseAdmin.from('clip_music_tracks').insert({
    title: String(b.title).slice(0, 120), mood, url: String(b.url),
    duration_s: parseInt(b.duration_s, 10) || 0, license_note: b.license_note || null, is_active: b.is_active !== false,
  }).select('id').maybeSingle();
  if (error) { res.status(500).json({ success: false, error: 'Création impossible' }); return; }
  res.json({ success: true, data });
});

// PATCH /api/clips/admin/music/:id — activer/désactiver / éditer.
router.patch('/admin/music/:id', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  if (!(await isPdg(req.user!.id))) { res.status(403).json({ success: false, error: 'PDG uniquement' }); return; }
  const b = req.body || {};
  const upd: Record<string, any> = {};
  if (b.is_active != null) upd.is_active = !!b.is_active;
  if (b.title) upd.title = String(b.title).slice(0, 120);
  if (['énergique', 'chill', 'afro', 'premium'].includes(b.mood)) upd.mood = b.mood;
  if (b.license_note !== undefined) upd.license_note = b.license_note;
  const { error } = await supabaseAdmin.from('clip_music_tracks').update(upd).eq('id', req.params.id);
  if (error) { res.status(500).json({ success: false, error: 'Mise à jour impossible' }); return; }
  res.json({ success: true, data: { updated: true } });
});

// DELETE /api/clips/admin/music/:id
router.delete('/admin/music/:id', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  if (!(await isPdg(req.user!.id))) { res.status(403).json({ success: false, error: 'PDG uniquement' }); return; }
  const { error } = await supabaseAdmin.from('clip_music_tracks').delete().eq('id', req.params.id);
  if (error) { res.status(500).json({ success: false, error: 'Suppression impossible' }); return; }
  res.json({ success: true, data: { deleted: true } });
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

// ── POST /api/clips/device/init : job 'device' + URLs signées d'upload (rendu sur le téléphone) ──
router.post('/device/init', verifyJWT, authRateLimit, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const vendor = await getVendorForUser(req.user!.id);
  if (!vendor) { res.status(403).json({ success: false, error: 'Compte vendeur introuvable' }); return; }
  const b = req.body || {};
  const idem = String(req.headers['idempotency-key'] || b.idempotency_key || '') || null;
  const { data: id, error } = await supabaseAdmin.rpc('create_clip_job', {
    p_vendor_id: vendor.id, p_stream_id: b.stream_id, p_title: b.title ?? null,
    p_segments: b.segments ?? [], p_overlay: b.overlay ?? {}, p_music_track_id: b.music_track_id ?? null,
    p_cover_time_s: b.cover_time_s ?? null, p_rendered_on: 'device', p_idempotency_key: idem,
  });
  if (error) { const e = mapClipError(error.message); res.status(e.code).json({ success: false, error: e.error }); return; }
  const base = `clips/${vendor.id}/${id}`;
  const [land, cover] = await Promise.all([
    supabaseAdmin.storage.from(CLIP_BUCKET).createSignedUploadUrl(`${base}/paysage.mp4`),
    supabaseAdmin.storage.from(CLIP_BUCKET).createSignedUploadUrl(`${base}/cover.jpg`),
  ]);
  if (land.error || cover.error || !land.data || !cover.data) { res.status(500).json({ success: false, error: 'URLs indisponibles' }); return; }
  res.json({ success: true, data: {
    id,
    landscape: { path: `${base}/paysage.mp4`, token: land.data.token },
    cover: { path: `${base}/cover.jpg`, token: cover.data.token },
  } });
});

// ── POST /api/clips/device/:id/complete : le téléphone a rendu+uploadé → passe en 'ready' ──
router.post('/device/:id/complete', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const vendor = await getVendorForUser(req.user!.id);
  if (!vendor) { res.status(403).json({ success: false, error: 'Compte vendeur introuvable' }); return; }
  const { data: clip } = await supabaseAdmin.from('live_clips').select('id, rendered_on').eq('id', req.params.id).eq('vendor_id', vendor.id).maybeSingle();
  if (!clip) { res.status(404).json({ success: false, error: 'Clip introuvable' }); return; }
  if ((clip as any).rendered_on !== 'device') { res.status(400).json({ success: false, error: 'Pas un clip appareil' }); return; }
  const base = `clips/${vendor.id}/${req.params.id}`;
  const land = supabaseAdmin.storage.from(CLIP_BUCKET).getPublicUrl(`${base}/paysage.mp4`).data.publicUrl;
  const cover = supabaseAdmin.storage.from(CLIP_BUCKET).getPublicUrl(`${base}/cover.jpg`).data.publicUrl;
  const { error } = await supabaseAdmin.from('live_clips').update({
    status: 'ready', progress: 100,
    output_url: land, output_vertical_url: land, thumbnail_url: req.body?.has_cover ? cover : null,
    duration_s: Number(req.body?.duration_s) || null, size_bytes: Number(req.body?.size_bytes) || null, error: null,
  }).eq('id', req.params.id).eq('vendor_id', vendor.id);
  if (error) { res.status(500).json({ success: false, error: 'Finalisation impossible' }); return; }
  res.json({ success: true, data: { ready: true } });
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
