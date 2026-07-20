/**
 * 🎬 STUDIO CLIPS — worker ffmpeg (Chantier A3). Traite les jobs live_clips rendered_on='server'.
 * Pipeline (temp dir dédié, nettoyé en finally) : download replay (GCS public) → découpe segments
 * (copy, fallback re-encode) → concat → habillage 720p (logo boutique + bandeau produit) en une
 * passe → musique (volume réglable + ducking + fondus in/out via clipFilters / loudnorm) →
 * version verticale 9:16 → couverture JPEG → upload GCS.
 * ffmpeg/ffprobe = binaires système (EC2). Args en TABLEAUX (jamais de concat shell → anti-injection).
 * Concurrence 1 (claim_next_clip_job avec SKIP LOCKED). Watchdog anti-zombie (clip_watchdog).
 */
import { execFile } from 'child_process';
import { promisify } from 'util';
import { promises as fs } from 'fs';
import os from 'os';
import path from 'path';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { buildAudioFilter, normalizeAudioOpts } from './clipFilters.js';

const pexec = promisify(execFile);
// Les clips vivent sur Supabase Storage (comme les replays/images) → public + CORS garantis.
export const CLIP_BUCKET = 'communication-files';
// 🔒 Les replays BRUTS vivent dans un bucket PRIVÉ (règle PDG : jamais publics).
// URL canonique stockée en base : https://<proj>/storage/v1/object/authenticated/live-replays/<path>
// (400/403 sans jeton — seule une URL signée courte, servie au vendeur, permet la lecture).
export const REPLAY_BUCKET = 'live-replays';
const PRIVATE_REPLAY_MARKER = `/storage/v1/object/authenticated/${REPLAY_BUCKET}/`;

/** Chemin objet d'une URL de replay privé (null si ce n'en est pas une). */
export function privateReplayPath(url: string): string | null {
  const i = String(url || '').indexOf(PRIVATE_REPLAY_MARKER);
  return i >= 0 ? decodeURIComponent(url.slice(i + PRIVATE_REPLAY_MARKER.length).split('?')[0]) : null;
}

/** URL canonique (non fetchable publiquement) d'un objet replay privé. */
export function privateReplayUrl(objectPath: string): string {
  const base = (process.env.SUPABASE_URL || '').replace(/\/$/, '');
  return `${base}/storage/v1/object/authenticated/${REPLAY_BUCKET}/${objectPath}`;
}
const FONT = '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf';
const BLUE = '0x04439E';

let running = false; // verrou process (concurrence 1 dans cette instance)

async function ff(args: string[], timeoutMs = 10 * 60 * 1000): Promise<void> {
  await pexec('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', ...args], { timeout: timeoutMs, maxBuffer: 1 << 24 });
}
async function ffprobeJson(file: string): Promise<any> {
  const { stdout } = await pexec('ffprobe', ['-v', 'quiet', '-print_format', 'json', '-show_format', '-show_streams', file], { maxBuffer: 1 << 24 });
  return JSON.parse(stdout);
}

/** Échappe un texte pour drawtext (les ' : \ % cassent le filtre). */
function esc(t: string): string {
  return String(t || '').replace(/\\/g, '\\\\').replace(/:/g, '\\:').replace(/'/g, "’").replace(/%/g, '\\%').slice(0, 80);
}

async function setProgress(id: string, p: number, extra: Record<string, any> = {}): Promise<void> {
  await supabaseAdmin.from('live_clips').update({ progress: p, ...extra }).eq('id', id);
}

/** Télécharge une URL (publique OU replay privé via service) vers un fichier local. */
async function download(url: string, dest: string): Promise<void> {
  const privatePath = privateReplayPath(url);
  if (privatePath) {
    const { data, error } = await supabaseAdmin.storage.from(REPLAY_BUCKET).download(privatePath);
    if (error || !data) throw new Error(`download privé ${error?.message || 'vide'}`);
    await fs.writeFile(dest, Buffer.from(await data.arrayBuffer()));
    return;
  }
  const r = await fetch(url);
  if (!r.ok) throw new Error(`download ${r.status}`);
  const buf = Buffer.from(await r.arrayBuffer());
  await fs.writeFile(dest, buf);
}

/** Upload d'un fichier local vers Supabase Storage → URL publique. */
async function uploadClipFile(localPath: string, objectPath: string, contentType: string): Promise<string> {
  const body = await fs.readFile(localPath);
  const { error } = await supabaseAdmin.storage.from(CLIP_BUCKET).upload(objectPath, body, { contentType, upsert: true });
  if (error) throw new Error(`upload ${error.message}`);
  return supabaseAdmin.storage.from(CLIP_BUCKET).getPublicUrl(objectPath).data.publicUrl;
}

interface ClipRow {
  id: string; vendor_id: string; stream_id: string | null;
  segments: Array<{ start_s: number; end_s: number }>;
  overlay: {
    product_name?: string; price?: number; currency?: string; show_logo?: boolean;
    audio?: { music_volume?: number; original_volume?: number; duck?: boolean; music_only?: boolean };
  };
  music_track_id: string | null; cover_time_s: number | null;
}

async function processClip(clip: ClipRow): Promise<void> {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), `clip-${clip.id}-`));
  try {
    // 0) Sources : replay + (logo boutique) + (musique).
    const { data: stream } = await supabaseAdmin.from('live_streams').select('replay_url').eq('id', clip.stream_id).maybeSingle();
    const replayUrl = (stream as any)?.replay_url;
    if (!replayUrl) throw new Error('REPLAY_INDISPONIBLE');
    const src = path.join(dir, 'src.mp4');
    await download(replayUrl, src);
    await setProgress(clip.id, 15);

    // Refus source > 2h (coût).
    const meta = await ffprobeJson(src);
    const srcDur = Number(meta?.format?.duration || 0);
    if (srcDur > 7200) throw new Error('SOURCE_TROP_LONGUE');

    // 1) Découpe chaque segment (copy rapide ; re-encode si lecture cassée).
    const segFiles: string[] = [];
    for (let i = 0; i < clip.segments.length; i++) {
      const s = clip.segments[i];
      const out = path.join(dir, `seg${i}.mp4`);
      try {
        await ff(['-ss', String(s.start_s), '-to', String(s.end_s), '-i', src, '-c', 'copy', '-avoid_negative_ts', '1', out]);
        await ffprobeJson(out); // valide
      } catch {
        await ff(['-ss', String(s.start_s), '-to', String(s.end_s), '-i', src, '-c:v', 'libx264', '-preset', 'veryfast', '-c:a', 'aac', out]);
      }
      segFiles.push(out);
    }
    await setProgress(clip.id, 40);

    // 2) Concat (demuxer).
    const listFile = path.join(dir, 'list.txt');
    await fs.writeFile(listFile, segFiles.map((f) => `file '${f.replace(/'/g, "'\\''")}'`).join('\n'));
    const raw = path.join(dir, 'raw.mp4');
    await ff(['-f', 'concat', '-safe', '0', '-i', listFile, '-c', 'copy', raw]).catch(async () => {
      await ff(['-f', 'concat', '-safe', '0', '-i', listFile, '-c:v', 'libx264', '-preset', 'veryfast', '-c:a', 'aac', raw]);
    });

    // 3) Habillage 720p en UNE passe : scale/pad + logo (bas-droite) + bandeau produit (bas).
    let logoLocal: string | null = null;
    if (clip.overlay?.show_logo) {
      const { data: v } = await supabaseAdmin.from('vendors').select('logo_url').eq('id', clip.vendor_id).maybeSingle();
      const logoUrl = (v as any)?.logo_url;
      if (logoUrl && /^https?:\/\//.test(logoUrl)) {
        try { logoLocal = path.join(dir, 'logo.png'); await download(logoUrl, logoLocal); } catch { logoLocal = null; }
      }
    }
    const priceLabel = clip.overlay?.price ? `${Number(clip.overlay.price).toLocaleString('fr-FR')} ${esc(clip.overlay.currency || 'GNF')}` : '';
    const bannerTxt = [esc(clip.overlay?.product_name || ''), priceLabel].filter(Boolean).join('   ');

    // Filtre : base scale+pad 1280x720 → [bg]; bandeau (drawbox bleu 80% + drawtext) ; logo overlay.
    const vf: string[] = [`[0:v]scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,setsar=1[base]`];
    let last = 'base';
    if (bannerTxt) {
      vf.push(`[${last}]drawbox=x=0:y=ih-96:w=iw:h=96:color=${BLUE}@0.8:t=fill[bx]`);
      vf.push(`[bx]drawtext=fontfile=${FONT}:text='${bannerTxt}':fontcolor=white:fontsize=34:x=40:y=h-64[bt]`);
      last = 'bt';
    }
    const filterInputs = ['-i', raw];
    if (logoLocal) {
      filterInputs.push('-i', logoLocal);
      vf.push(`[1:v]scale=iw*0.12:-1[lg]`);
      vf.push(`[${last}][lg]overlay=W-w-24:H-h-120:format=auto[vout]`);
      last = 'vout';
    } else {
      vf.push(`[${last}]null[vout]`);
      last = 'vout';
    }

    // 4) Audio : musique en fond (volume réglable + fondu in/out + ducking) ou loudnorm de
    //    l'audio d'origine. Filtre construit par clipFilters.buildAudioFilter (testé unitairement).
    const body = path.join(dir, 'body.mp4');
    const totalDur = clip.segments.reduce((a, s) => a + (s.end_s - s.start_s), 0);
    let musicLocal: string | null = null;
    if (clip.music_track_id) {
      const { data: mt } = await supabaseAdmin.from('clip_music_tracks').select('url').eq('id', clip.music_track_id).eq('is_active', true).maybeSingle();
      const murl = (mt as any)?.url;
      if (murl && /^https?:\/\//.test(murl)) { try { musicLocal = path.join(dir, 'music.m4a'); await download(murl, musicLocal); } catch { musicLocal = null; } }
    }
    const hasMusic = !!musicLocal;
    if (hasMusic) filterInputs.push('-stream_loop', '-1', '-i', musicLocal!);
    const audioOpts = normalizeAudioOpts(clip.overlay?.audio, {
      hasMusic,
      musicInputIndex: logoLocal ? 2 : 1, // 0=raw, [1=logo], puis musique
      totalDurationS: totalDur,
    });
    const filter = vf.join(';') + ';' + buildAudioFilter(audioOpts);
    await ff([...filterInputs, '-filter_complex', filter, '-map', `[${last}]`, '-map', '[aout]',
      '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '26', '-pix_fmt', 'yuv420p', '-c:a', 'aac',
      ...(hasMusic ? ['-shortest'] : []), body]);
    await setProgress(clip.id, 70);

    // 5) Version verticale 9:16 (1080x1920) : fond flouté + vidéo centrée (meilleur rendu que crop).
    const vertical = path.join(dir, 'vertical.mp4');
    await ff(['-i', body, '-filter_complex',
      `[0:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,boxblur=20:2[bg];[0:v]scale=1080:-1[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2[v]`,
      '-map', '[v]', '-map', '0:a?', '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '26', '-pix_fmt', 'yuv420p', '-c:a', 'aac', vertical]);

    // 6) Couverture : frame à cover_time_s (défaut : milieu du 1er segment) → JPEG.
    const firstDur = clip.segments[0].end_s - clip.segments[0].start_s;
    const coverT = clip.cover_time_s != null ? Math.max(0, Number(clip.cover_time_s)) : Math.min(firstDur / 2, 3);
    const cover = path.join(dir, 'cover.jpg');
    await ff(['-ss', String(coverT), '-i', body, '-frames:v', '1', '-vf', 'scale=1280:-1', '-q:v', '4', cover]);
    await setProgress(clip.id, 85);

    // 7) Upload des 3 fichiers.
    const base = `clips/${clip.vendor_id}/${clip.id}`;
    const outputUrl = await uploadClipFile(body, `${base}/paysage.mp4`, 'video/mp4');
    const verticalUrl = await uploadClipFile(vertical, `${base}/vertical.mp4`, 'video/mp4');
    const thumbUrl = await uploadClipFile(cover, `${base}/cover.jpg`, 'image/jpeg');

    const outMeta = await ffprobeJson(body);
    const outDur = Number(outMeta?.format?.duration || 0);
    // 🔒 Verrou 5:00 sur la SORTIE RÉELLE (ffprobe) — la validation création ne
    // suffit pas (règle inviolable) : > max + 2 s de tolérance → failed, jamais publié.
    const { data: cfg } = await supabaseAdmin.from('clip_config').select('max_clip_duration_s').eq('id', true).maybeSingle();
    const maxS = Number((cfg as any)?.max_clip_duration_s || 300);
    if (outDur > maxS + 2) throw new Error(`DUREE_SORTIE_DEPASSEE (${Math.round(outDur)}s > ${maxS}s)`);
    const stat = await fs.stat(body);
    await supabaseAdmin.from('live_clips').update({
      status: 'ready', progress: 100,
      output_url: outputUrl, output_vertical_url: verticalUrl, thumbnail_url: thumbUrl,
      duration_s: outDur, size_bytes: stat.size, error: null,
    }).eq('id', clip.id);
    logger.info(`[clips] ${clip.id} ready (${Math.round(stat.size / 1e6)}MB)`);
  } catch (e: any) {
    const msg = String(e?.message || e).slice(0, 400);
    logger.error(`[clips] ${clip.id} failed: ${msg}`);
    await supabaseAdmin.from('live_clips').update({ status: 'failed', error: msg }).eq('id', clip.id);
  } finally {
    await fs.rm(dir, { recursive: true, force: true }).catch(() => {});
  }
}

/** Récurrent : prend UN job serveur en attente et le traite entièrement (concurrence 1). */
export async function processQueuedClips(): Promise<void> {
  if (running) return;
  running = true;
  try {
    const { data, error } = await supabaseAdmin.rpc('claim_next_clip_job');
    if (error) { logger.error(`[clips] claim: ${error.message}`); return; }
    // RETURNS composite : file vide ⇒ PostgREST renvoie une ligne toute NULL (pas null) →
    // sans ce garde, le worker traite un job fantôme id=null en boucle (erreur toutes les 30 s).
    if (!data || !(data as ClipRow).id) return; // rien en file
    await processClip(data as ClipRow);
  } finally {
    running = false;
  }
}

/** Récurrent : passe en 'failed' les jobs 'processing' figés > 15 min. */
export async function runClipWatchdog(): Promise<void> {
  const { data, error } = await supabaseAdmin.rpc('clip_watchdog');
  if (error) { logger.error(`[clips] watchdog: ${error.message}`); return; }
  if (data && Number(data) > 0) logger.warn(`[clips] watchdog: ${data} job(s) zombie → failed`);
}

/**
 * 🔧 P1 Studio — TRANSCODAGE des replays webm → mp4 H.264/AAC (+faststart).
 * Cause racine du « lecteur noir » du Studio : MediaRecorder produit du .webm,
 * (1) illisible sur iPhone/Safari (le <video> reste noir, durée jamais connue,
 * montage mort en cascade) et (2) souvent SANS métadonnée de durée même sur
 * Chrome. Couvre les NOUVEAUX replays ET le backfill des existants.
 * 1 replay par tick (CPU EC2), 3 tentatives max par process (anti-boucle).
 */
const transcodeFailures = new Map<string, number>();
export async function processReplayTranscodes(): Promise<void> {
  const { data } = await supabaseAdmin.from('live_streams')
    .select('id, replay_url').like('replay_url', '%.webm').limit(5);
  const rows = ((data as any[]) || []).filter((r) => (transcodeFailures.get(r.id) || 0) < 3);
  const r = rows[0];
  if (!r) return;
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'replaymp4-'));
  try {
    const src = path.join(dir, 'src.webm');
    await download(r.replay_url, src);
    const out = path.join(dir, 'replay.mp4');
    await ff(['-i', src, '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23', '-pix_fmt', 'yuv420p',
      '-c:a', 'aac', '-movflags', '+faststart', out], 20 * 60 * 1000);
    const meta = await ffprobeJson(out);
    if (!Number(meta?.format?.duration)) throw new Error('sortie sans durée');
    // 🔒 Le mp4 transcodé va dans le bucket PRIVÉ (les replays bruts ne sont jamais publics).
    const objectPath = `raw/${r.id}.mp4`;
    const bodyBuf = await fs.readFile(out);
    const { error: upErr } = await supabaseAdmin.storage.from(REPLAY_BUCKET)
      .upload(objectPath, bodyBuf, { contentType: 'video/mp4', upsert: true });
    if (upErr) throw new Error(`upload privé ${upErr.message}`);
    await supabaseAdmin.from('live_streams').update({ replay_url: privateReplayUrl(objectPath) }).eq('id', r.id);
    logger.info(`[replay-mp4] ${r.id} transcodé privé (${Math.round(Number(meta.format.duration))}s)`);
  } catch (e: any) {
    transcodeFailures.set(r.id, (transcodeFailures.get(r.id) || 0) + 1);
    logger.error(`[replay-mp4] ${r.id}: ${String(e?.message || e).slice(0, 200)}`);
  } finally {
    await fs.rm(dir, { recursive: true, force: true }).catch(() => {});
  }
}

/**
 * A4 — miniatures des REPLAYS (fix de l'aperçu OG des lives). Couvre les nouveaux replays ET le
 * backfill des anciens : frame à 25 % de la durée (ffmpeg en lecture HTTP directe du GCS public,
 * pas de download complet) → JPEG → upload GCS → thumbnail_url. Traite un petit lot par tick.
 */
export async function processReplayThumbnails(): Promise<void> {
  const { data } = await supabaseAdmin.from('live_streams')
    .select('id, replay_url').not('replay_url', 'is', null).is('thumbnail_url', null).limit(5);
  const rows = (data as any[]) || [];
  if (!rows.length) return;
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'replaythumb-'));
  try {
    for (const r of rows) {
      try {
        // Replays privés : ffmpeg ne peut plus lire l'URL en HTTP → download service d'abord.
        let input = r.replay_url as string;
        if (privateReplayPath(input)) {
          input = path.join(dir, `${r.id}-src`);
          await download(r.replay_url, input);
        }
        let t = 1;
        try { const meta = await ffprobeJson(input); const d = Number(meta?.format?.duration || 0); if (d > 0) t = d * 0.25; } catch { /* durée inconnue → 1 s */ }
        const out = path.join(dir, `${r.id}.jpg`);
        await ff(['-ss', String(t), '-i', input, '-frames:v', '1', '-vf', 'scale=1280:-1', '-q:v', '4', out], 120000);
        const url = await uploadClipFile(out, `live-thumbnails/${r.id}.jpg`, 'image/jpeg');
        await supabaseAdmin.from('live_streams').update({ thumbnail_url: url }).eq('id', r.id);
        logger.info(`[replay-thumb] ${r.id} ok`);
      } catch (e: any) { logger.error(`[replay-thumb] ${r.id}: ${String(e?.message || e).slice(0, 200)}`); }
    }
  } finally { await fs.rm(dir, { recursive: true, force: true }).catch(() => {}); }
}

/**
 * 🎬 P2 — RAPPEL J+1 du parcours guidé : un replay d'hier sans clip → notification
 * « Votre live d'hier attend son clip ». Une seule fois (clip_reminder_sent_at).
 */
export async function processClipReminders(): Promise<void> {
  const { createNotification } = await import('../services/notification.service.js');
  const { data } = await supabaseAdmin.from('live_streams')
    .select('id, title, vendor_user_id')
    .not('replay_url', 'is', null)
    .is('clip_reminder_sent_at', null)
    .lt('ended_at', new Date(Date.now() - 24 * 3600e3).toISOString())
    .gt('ended_at', new Date(Date.now() - 72 * 3600e3).toISOString())
    .limit(20);
  for (const r of ((data as any[]) || [])) {
    const { count } = await supabaseAdmin.from('live_clips')
      .select('id', { count: 'exact', head: true }).eq('stream_id', r.id);
    if (!count) {
      await createNotification({
        userId: r.vendor_user_id,
        title: '🎬 Votre live attend son clip',
        message: `« ${r.title} » : créez un clip (≤ 5 min) au Studio pour le publier — le replay brut reste privé.`,
        type: 'clip_reminder',
        metadata: { link: `/studio-clips?stream=${r.id}` },
      }).catch(() => {});
    }
    await supabaseAdmin.from('live_streams').update({ clip_reminder_sent_at: new Date().toISOString() }).eq('id', r.id);
  }
}

/**
 * 🧹 P2 — RÉTENTION de la matière première : purge des replays bruts NON MONTÉS
 * au-delà de clip_config.raw_replay_retention_days (défaut 30), avec
 * avertissement J-3 (« votre replay expire — montez-le »). Les clips générés
 * restent. Gère les fichiers privés (bucket live-replays) et l'héritage public
 * Supabase ; les URLs GCS sont laissées à l'ancienne purge (loggé).
 */
export async function processReplayRetention(): Promise<void> {
  const { createNotification } = await import('../services/notification.service.js');
  const { data: cfg } = await supabaseAdmin.from('clip_config').select('raw_replay_retention_days').eq('id', true).maybeSingle();
  const days = Math.max(3, Number((cfg as any)?.raw_replay_retention_days || 30));
  const now = Date.now();

  // 1) Avertissement J-3 (une seule fois), seulement si aucun clip prêt n'existe.
  const warnBefore = new Date(now - (days - 3) * 86400e3).toISOString();
  const { data: toWarn } = await supabaseAdmin.from('live_streams')
    .select('id, title, vendor_user_id')
    .not('replay_url', 'is', null)
    .is('replay_expiry_notified_at', null)
    .lt('ended_at', warnBefore)
    .limit(20);
  for (const r of ((toWarn as any[]) || [])) {
    const { count } = await supabaseAdmin.from('live_clips')
      .select('id', { count: 'exact', head: true }).eq('stream_id', r.id).eq('status', 'ready');
    if (!count) {
      await createNotification({
        userId: r.vendor_user_id,
        title: '⏳ Votre replay expire bientôt',
        message: `« ${r.title} » sera purgé dans 3 jours — montez-le au Studio pour garder un clip.`,
        type: 'replay_expiry',
        metadata: { link: `/studio-clips?stream=${r.id}` },
      }).catch(() => {});
    }
    await supabaseAdmin.from('live_streams').update({ replay_expiry_notified_at: new Date().toISOString() }).eq('id', r.id);
  }

  // 2) Purge au-delà de la rétention — le fichier est supprimé, la ligne et les
  //    clips restent (replay_url → null). GCS : loggé, purge existante conservée.
  const purgeBefore = new Date(now - days * 86400e3).toISOString();
  const { data: toPurge } = await supabaseAdmin.from('live_streams')
    .select('id, replay_url').not('replay_url', 'is', null).lt('ended_at', purgeBefore).limit(20);
  let purged = 0;
  for (const r of ((toPurge as any[]) || [])) {
    const url = String(r.replay_url);
    const privatePath = privateReplayPath(url);
    const publicMarker = `/object/public/${CLIP_BUCKET}/`;
    const pubIdx = url.indexOf(publicMarker);
    try {
      if (privatePath) {
        const { error } = await supabaseAdmin.storage.from(REPLAY_BUCKET).remove([privatePath]);
        if (error && !/not.*found/i.test(error.message)) throw new Error(error.message);
      } else if (pubIdx >= 0) {
        const p = decodeURIComponent(url.slice(pubIdx + publicMarker.length).split('?')[0]);
        const { error } = await supabaseAdmin.storage.from(CLIP_BUCKET).remove([p]);
        if (error && !/not.*found/i.test(error.message)) throw new Error(error.message);
      } else {
        logger.warn(`[replay-retention] ${r.id}: URL non gérée (GCS ?) — laissée à live-replays.purge`);
        continue;
      }
      await supabaseAdmin.from('live_streams').update({ replay_url: null }).eq('id', r.id);
      purged++;
    } catch (e: any) {
      logger.error(`[replay-retention] ${r.id}: ${String(e?.message || e).slice(0, 200)}`);
    }
  }
  if (purged) logger.info(`[replay-retention] ${purged} replay(s) brut(s) purgés (> ${days} j)`);
}
