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
