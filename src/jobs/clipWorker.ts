/**
 * 🎬 STUDIO CLIPS — worker ffmpeg (Chantier A3). Traite les jobs live_clips rendered_on='server'.
 * Pipeline (temp dir dédié, nettoyé en finally) : download replay (GCS public) → découpe segments
 * (copy, fallback re-encode) → concat → habillage 720p (logo boutique + bandeau produit) en une
 * passe → musique (amix -18dB / loudnorm) → version verticale 9:16 → couverture JPEG → upload GCS.
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
import { loadServiceAccount, getBucketName, generateSignedUrl } from '../services/gcs.service.js';

const pexec = promisify(execFile);
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

/** Télécharge une URL publique vers un fichier local. */
async function download(url: string, dest: string): Promise<void> {
  const r = await fetch(url);
  if (!r.ok) throw new Error(`download ${r.status}`);
  const buf = Buffer.from(await r.arrayBuffer());
  await fs.writeFile(dest, buf);
}

/** Upload d'un fichier local vers GCS (URL signée PUT) → URL publique. */
async function uploadGcs(localPath: string, objectPath: string, contentType: string): Promise<string> {
  const sa = loadServiceAccount();
  const bucket = getBucketName();
  if (!sa || !bucket) throw new Error('GCS non configuré');
  const signed = generateSignedUrl(sa, bucket, objectPath, { method: 'PUT', expiresInSeconds: 600 });
  const body = await fs.readFile(localPath);
  const resp = await fetch(signed, { method: 'PUT', headers: { 'content-type': contentType }, body });
  if (!resp.ok) throw new Error(`GCS upload ${resp.status}`);
  return `https://${bucket}.storage.googleapis.com/${objectPath}`;
}

interface ClipRow {
  id: string; vendor_id: string; stream_id: string | null;
  segments: Array<{ start_s: number; end_s: number }>;
  overlay: { product_name?: string; price?: number; currency?: string; show_logo?: boolean };
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

    // 4) Audio : musique en fond (-18dB, fondu 2s) ou loudnorm de l'audio d'origine.
    const body = path.join(dir, 'body.mp4');
    let musicLocal: string | null = null;
    if (clip.music_track_id) {
      const { data: mt } = await supabaseAdmin.from('clip_music_tracks').select('url').eq('id', clip.music_track_id).eq('is_active', true).maybeSingle();
      const murl = (mt as any)?.url;
      if (murl && /^https?:\/\//.test(murl)) { try { musicLocal = path.join(dir, 'music.m4a'); await download(murl, musicLocal); } catch { musicLocal = null; } }
    }
    if (musicLocal) {
      filterInputs.push('-stream_loop', '-1', '-i', musicLocal);
      const musicIdx = logoLocal ? 2 : 1;
      const af = `[0:a]aresample=async=1[a0];[${musicIdx}:a]volume=-18dB,afade=t=out:st=0:d=2[am];[a0][am]amix=inputs=2:duration=first:dropout_transition=2[aout]`;
      const filter = vf.join(';') + ';' + af;
      await ff([...filterInputs, '-filter_complex', filter, '-map', `[${last}]`, '-map', '[aout]',
        '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '26', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', body]);
    } else {
      const filter = vf.join(';') + ';[0:a]loudnorm[aout]';
      await ff([...filterInputs, '-filter_complex', filter, '-map', `[${last}]`, '-map', '[aout]',
        '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '26', '-pix_fmt', 'yuv420p', '-c:a', 'aac', body]);
    }
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
    const outputUrl = await uploadGcs(body, `${base}/paysage.mp4`, 'video/mp4');
    const verticalUrl = await uploadGcs(vertical, `${base}/vertical.mp4`, 'video/mp4');
    const thumbUrl = await uploadGcs(cover, `${base}/cover.jpg`, 'image/jpeg');

    const outMeta = await ffprobeJson(body);
    const stat = await fs.stat(body);
    await supabaseAdmin.from('live_clips').update({
      status: 'ready', progress: 100,
      output_url: outputUrl, output_vertical_url: verticalUrl, thumbnail_url: thumbUrl,
      duration_s: Number(outMeta?.format?.duration || 0), size_bytes: stat.size, error: null,
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
    if (!data) return; // rien en file
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
