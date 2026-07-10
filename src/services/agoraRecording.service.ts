/**
 * 🎥 AGORA CLOUD RECORDING — replay serveur GARANTI (CHANTIER 2, FIX A).
 *
 * Agora enregistre le live sur SES serveurs (mode « mix » = host + co-hôtes en UN fichier) et
 * dépose le MP4 DIRECTEMENT dans notre bucket GCS (API S3-compatible). Le téléphone du vendeur ne
 * participe PLUS au replay → le replay se publie même si le vendeur ferme l'app.
 *
 * BEST-EFFORT ABSOLU : le démarrage/la clôture du live ne sont JAMAIS bloqués par le recording.
 * Secrets EN process.env UNIQUEMENT (jamais en base) : AGORA_CUSTOMER_ID/SECRET (Basic auth REST,
 * ≠ App Certificate) + GCS_HMAC_ACCESS_KEY/SECRET (clé HMAC GCS pour l'écriture S3-compatible).
 * Absents → l'enregistrement serveur est DÉSACTIVÉ silencieusement (le repli client prend le relais).
 */
import { env } from '../config/env.js';
import { logger } from '../config/logger.js';
import { supabaseAdmin } from '../config/supabase.js';
import { getBucketName } from './gcs.service.js';
import { generateAgoraRtcToken, AgoraRole } from './agoraToken.js';

// UID DÉDIÉ du recorder, garanti hors de l'espace de hash uuidToNumericUid ([0..2147483646])
// → ne peut JAMAIS collisionner avec le host ni un co-host. ≤ uid max Agora (4294967295).
const RECORDER_UID = '2147483647';
const REC_STORAGE_PREFIX = 'live-replays';

/** Les 4 secrets requis sont-ils présents ? Sinon, enregistrement serveur DÉSACTIVÉ. */
export function isCloudRecordingConfigured(): boolean {
  return !!(env.AGORA_APP_ID && env.AGORA_APP_CERTIFICATE
    && env.AGORA_CUSTOMER_ID && env.AGORA_CUSTOMER_SECRET
    && env.GCS_HMAC_ACCESS_KEY && env.GCS_HMAC_SECRET);
}

function apiBase(): string {
  return `https://api.agora.io/v1/apps/${env.AGORA_APP_ID}/cloud_recording`;
}
function basicAuth(): string {
  return 'Basic ' + Buffer.from(`${env.AGORA_CUSTOMER_ID}:${env.AGORA_CUSTOMER_SECRET}`).toString('base64');
}
async function post(path: string, body: unknown): Promise<any> {
  const r = await fetch(`${apiBase()}${path}`, {
    method: 'POST',
    headers: { Authorization: basicAuth(), 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(`agora ${path} ${r.status}: ${JSON.stringify(data).slice(0, 300)}`);
  return data;
}

// storageConfig GCS (vendor=6). Agora écrit via l'API S3-compatible (Interoperability) → clé HMAC.
function storageConfig(streamId: string) {
  return {
    vendor: 6,           // 6 = Google Cloud Storage
    region: 0,           // requis mais ignoré par Agora pour GCS
    bucket: getBucketName(),
    accessKey: env.GCS_HMAC_ACCESS_KEY,
    secretKey: env.GCS_HMAC_SECRET,
    fileNamePrefix: [REC_STORAGE_PREFIX, streamId],
  };
}

/** Construit l'URL publique GCS (path-style) d'un fichier écrit par Agora (validée par isAllowedThumbnailUrl). */
function gcsUrl(fileName: string): string {
  return `https://storage.googleapis.com/${getBucketName()}/${fileName}`;
}

/** Extrait l'URL du MP4 du serverResponse Agora (fileList), ou null si pas encore prêt. */
function extractMp4Url(serverResponse: any): string | null {
  const list: any[] = serverResponse?.fileList || [];
  const arr = Array.isArray(list) ? list : [];
  const mp4 = arr.find((f) => typeof f?.fileName === 'string' && f.fileName.toLowerCase().endsWith('.mp4'));
  return mp4?.fileName ? gcsUrl(mp4.fileName) : null;
}

/**
 * DÉMARRE l'enregistrement serveur (best-effort, fire-and-forget côté route). acquire → start →
 * persiste resource_id/sid/uid + recording_status='recording' sur live_streams.
 */
export async function startLiveRecording(opts: { streamId: string; channel: string }): Promise<void> {
  if (!isCloudRecordingConfigured()) return; // désactivé → repli client
  const { streamId, channel } = opts;
  const nowTs = Math.floor(Date.now() / 1000);
  const token = generateAgoraRtcToken(env.AGORA_APP_ID, env.AGORA_APP_CERTIFICATE, channel, RECORDER_UID, AgoraRole.SUBSCRIBER, nowTs + 86400);

  // 1) acquire → resourceId
  const acq = await post('/acquire', {
    cname: channel, uid: RECORDER_UID,
    clientRequest: { resourceExpiredHour: 24, scene: 0 },
  });
  const resourceId: string = acq?.resourceId;
  if (!resourceId) throw new Error('acquire: resourceId manquant');

  // 2) start (mode mix, portrait 720×1280, MP4+HLS, storage GCS direct)
  const start = await post(`/resourceid/${resourceId}/mode/mix/start`, {
    cname: channel, uid: RECORDER_UID,
    clientRequest: {
      token,
      recordingConfig: {
        maxIdleTime: 60,            // stop auto si le canal se vide 60 s (anti-facturation)
        streamTypes: 2,            // audio + vidéo
        channelType: 1,            // live broadcasting
        videoStreamType: 0,
        subscribeUidGroup: 0,
        transcodingConfig: {
          width: 720, height: 1280, fps: 15, bitrate: 1130,  // portrait mobile 720p
          mixedVideoLayout: 1,     // best fit (host + co-hôtes)
          backgroundColor: '#000000',
        },
      },
      recordingFileConfig: { avFileType: ['hls', 'mp4'] },
      storageConfig: storageConfig(streamId),
    },
  });
  const sid: string = start?.sid;
  if (!sid) throw new Error('start: sid manquant');

  await supabaseAdmin.from('live_streams').update({
    recording_resource_id: resourceId, recording_sid: sid, recording_uid: RECORDER_UID, recording_status: 'recording',
  }).eq('id', streamId);
  logger.info(`[live/recording] démarré ${streamId} sid=${sid}`);
}

/**
 * ARRÊTE l'enregistrement (best-effort). Renvoie l'URL MP4 si Agora l'a déjà finalisée au stop,
 * sinon null (le worker filet finalisera). Met à jour recording_status.
 */
export async function stopLiveRecording(opts: {
  streamId: string; channel: string; resourceId: string; sid: string; recordingUid?: string;
}): Promise<string | null> {
  if (!isCloudRecordingConfigured()) return null;
  const { streamId, channel, resourceId, sid } = opts;
  const uid = opts.recordingUid || RECORDER_UID;
  let mp4Url: string | null = null;
  try {
    const res = await post(`/resourceid/${resourceId}/sid/${sid}/mode/mix/stop`, {
      cname: channel, uid, clientRequest: { async_stop: false },
    });
    mp4Url = extractMp4Url(res?.serverResponse);
  } catch (e: any) {
    // Déjà stoppé (maxIdleTime) ou erreur : on marque 'processing', le worker filet re-vérifiera.
    logger.warn(`[live/recording] stop ${streamId}: ${e?.message}`);
  }
  await supabaseAdmin.from('live_streams').update({
    recording_status: mp4Url ? 'ready' : 'processing',
    ...(mp4Url ? { replay_url: mp4Url, replay_expires_at: new Date(Date.now() + 30 * 24 * 3600 * 1000).toISOString() } : {}),
  }).eq('id', streamId).is('replay_url', null); // ne jamais écraser un replay déjà publié
  return mp4Url;
}

/**
 * Filet WORKER : pour un stream ENDED dont le recording est 'recording'/'processing' sans replay_url,
 * tente le stop (idempotent) et publie le MP4 s'il est prêt. Renvoie l'URL publiée ou null.
 */
export async function finalizeRecordingIfReady(row: {
  id: string; channel: string; recording_resource_id: string; recording_sid: string; recording_uid?: string | null;
}): Promise<string | null> {
  if (!isCloudRecordingConfigured()) return null;
  return stopLiveRecording({
    streamId: row.id, channel: row.channel, resourceId: row.recording_resource_id,
    sid: row.recording_sid, recordingUid: row.recording_uid || RECORDER_UID,
  });
}
