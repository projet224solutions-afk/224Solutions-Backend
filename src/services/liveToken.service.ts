/**
 * 🎫 issueLiveToken — fabrique de token de transport live, NEUTRE vis-à-vis du fournisseur.
 *
 * Vague 1 (agora) : RÉUTILISE l'edge function `agora-token` (qui détient déjà
 * AGORA_APP_ID/CERTIFICATE et la crypto du token 006) — on ne réécrit PAS la crypto et on
 * n'ajoute AUCUN secret Agora au backend. On proxifie avec le JWT de l'appelant (le host/viewer
 * est authentifié) ; l'edge mappe role 'publisher'→PUBLISHER, autre→SUBSCRIBER.
 *
 * Vague 2 (livekit) : stub — un token LiveKit signé serveur (voir
 * docs/LIVE_TRANSPORT_ARCHITECTURE.md). Aucune autre partie du code ne change.
 */

import { env } from '../config/env.js';
import { logger } from '../config/logger.js';
import {
  generateAgoraRtcToken,
  sanitizeAgoraChannel,
  uuidToNumericUid,
  AgoraRole,
} from './agoraToken.js';

/** Extrait le `sub` (userId) d'un JWT sans vérifier la signature (déjà vérifiée par verifyJWT en amont). */
function subFromJwt(jwt: string): string | null {
  try {
    const payload = jwt.split('.')[1];
    if (!payload) return null;
    const b64 = payload.replace(/-/g, '+').replace(/_/g, '/');
    const padded = b64.padEnd(b64.length + ((4 - (b64.length % 4)) % 4), '=');
    const json = JSON.parse(Buffer.from(padded, 'base64').toString('utf8'));
    return typeof json?.sub === 'string' ? json.sub : null;
  } catch {
    return null;
  }
}

export type LiveProvider = 'agora' | 'livekit';
export type LiveTokenRole = 'host' | 'audience';

export interface IssuedLiveToken {
  provider: LiveProvider;
  token: string;
  channel: string;
  uid: string;
  appId?: string;
  expiresAt?: number;
}

export function currentLiveProvider(): LiveProvider {
  return (env.LIVE_PROVIDER as LiveProvider) || 'agora';
}

/**
 * Émet un token pour le canal + rôle demandés.
 * @param userJwt  JWT de l'appelant (transmis à l'edge agora-token pour authentification).
 */
export async function issueLiveToken(
  provider: LiveProvider,
  channel: string,
  role: LiveTokenRole,
  uid: string | undefined,
  userJwt: string,
): Promise<IssuedLiveToken> {
  switch (provider) {
    case 'livekit':
      throw new Error('LiveKit non implémenté (Vague 2) — voir docs/LIVE_TRANSPORT_ARCHITECTURE.md');

    case 'agora':
    default: {
      // ── Chemin CANONIQUE : génération NATIVE Node quand le certificat est en env. ──
      // Le certificat Agora vit dans le backend (source de vérité), on signe ici : Agora
      // accepte le token au join. (L'edge Supabase signait avec un certificat périmé → rejet.)
      const appId = env.AGORA_APP_ID;
      const appCert = env.AGORA_APP_CERTIFICATE;
      if (appId && appCert) {
        const safeChannel = sanitizeAgoraChannel(channel);
        const trimmed = typeof uid === 'string' ? uid.trim() : '';
        const sub = subFromJwt(userJwt);
        const uidStr =
          trimmed.length > 0
            ? trimmed.substring(0, 64)
            : String(uuidToNumericUid(sub || '00000000-0000-0000-0000-000000000000'));
        const expiresAt = Math.floor(Date.now() / 1000) + 86400; // 24 h, comme l'edge
        const roleValue = role === 'host' ? AgoraRole.PUBLISHER : AgoraRole.SUBSCRIBER;
        const token = generateAgoraRtcToken(appId, appCert, safeChannel, uidStr, roleValue, expiresAt);
        return { provider: 'agora', token, channel: safeChannel, uid: uidStr, appId, expiresAt };
      }

      // ── Repli TRANSITOIRE : edge Supabase (si le certificat n'est pas encore en env). ──
      logger.warn('[issueLiveToken] AGORA_APP_ID/CERTIFICATE absents du backend — repli sur l\'edge (certificat potentiellement périmé)');
      const supabaseUrl = env.SUPABASE_URL?.replace(/\/$/, '');
      if (!supabaseUrl) throw new Error('SUPABASE_URL manquant');
      const resp = await fetch(`${supabaseUrl}/functions/v1/agora-token`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          apikey: env.SUPABASE_ANON_KEY || '',
          Authorization: `Bearer ${userJwt}`,
        },
        body: JSON.stringify({
          channel,
          uid,
          role: role === 'host' ? 'publisher' : 'subscriber',
        }),
      });
      const body = await resp.json().catch(() => ({}));
      if (!resp.ok || !body?.token) {
        logger.error(`[issueLiveToken] agora-token a échoué (${resp.status}): ${JSON.stringify(body).slice(0, 200)}`);
        throw new Error(body?.error || body?.reason || 'Échec émission du token live');
      }
      return {
        provider: 'agora',
        token: body.token,
        channel: body.channel || channel,
        uid: String(body.uid ?? uid ?? ''),
        appId: body.appId,
        expiresAt: body.expiresAt,
      };
    }
  }
}
