/**
 * ÉLECTION DE LEADER POUR LE WORKER (jobs de fond).
 *
 * Permet de lancer PLUSIEURS workers pour la haute disponibilité, tout en
 * garantissant qu'UN SEUL exécute les jobs à la fois (le « leader »).
 * Le leader détient un verrou Redis qu'il renouvelle par heartbeat. Si le
 * leader meurt (heartbeat arrêté), le verrou expire et un autre worker le prend.
 *
 * Si Redis est indisponible : on retombe sur le comportement historique
 * (le worker s'active quand même → le mode mono-instance reste fonctionnel).
 *
 * NOTE d'implémentation (adapté au client Redis réel de ce projet) :
 *  - getRedis() est ASYNC → on l'await.
 *  - le type RedisClient.set impose la condition 'NX' (acquisition atomique) ;
 *    pour le RENOUVELLEMENT (TTL only), on vérifie la possession via get() puis
 *    on rafraîchit avec expire() — pas de set() 4-args (non typé ici).
 *  - sur ERREUR Redis transitoire (client présent mais commande qui échoue), on
 *    PRÉSERVE l'état courant (le leader reste leader, le suiveur reste suiveur)
 *    pour éviter un split-brain (double exécution des jobs). Sur ABSENCE de Redis
 *    (client null), on s'active (mono-instance documenté).
 */
import { getRedis, isRedisConnected } from '../config/redis.js';
import { logger } from '../config/logger.js';
import { randomUUID } from 'crypto';

const LEADER_KEY = '224:worker:leader';
const LEADER_TTL_SECONDS = 30;        // le verrou expire après 30s sans heartbeat
const HEARTBEAT_INTERVAL_MS = 10_000; // renouvellement toutes les 10s

const instanceId = randomUUID();
let isLeader = false;
let heartbeatTimer: NodeJS.Timeout | null = null;

/**
 * Tente d'acquérir (si suiveur) ou de renouveler (si leader) le verrou.
 * NE MUTE PAS `isLeader` — c'est `tick()` qui possède toutes les transitions
 * d'état et déclenche les callbacks. Reçoit l'état courant en paramètre.
 * Retourne true si cette instance doit être leader après ce tick.
 */
async function tryAcquireOrRenew(currentlyLeader: boolean): Promise<boolean> {
  const redis = await getRedis();

  // Pas de Redis (désactivé / injoignable) → comportement historique : on
  // s'active (mono-instance). En multi-worker, un Redis partagé est requis.
  if (!redis) {
    if (!currentlyLeader) {
      logger.warn('[worker-leader] Redis indisponible → activation directe (mono-instance)');
    }
    return true;
  }

  try {
    if (currentlyLeader) {
      // Renouveler SEULEMENT si on détient encore le verrou (évite de voler
      // celui d'un autre si on l'a perdu pendant une pause GC/réseau).
      const current = await redis.get(LEADER_KEY);
      if (current === instanceId) {
        await redis.expire(LEADER_KEY, LEADER_TTL_SECONDS);
        return true;
      }
      logger.warn('[worker-leader] Leadership perdu (verrou pris par un autre / expiré)');
      return false;
    }

    // Suiveur : tenter d'acquérir (SET NX EX = atomique).
    const acquired = await redis.set(LEADER_KEY, instanceId, 'EX', LEADER_TTL_SECONDS, 'NX');
    if (acquired === 'OK') {
      logger.info(`[worker-leader] 👑 Cette instance devient LEADER (${instanceId.slice(0, 8)})`);
      return true;
    }
    return false;
  } catch (e: any) {
    // Erreur transitoire : préserver l'état courant (anti split-brain).
    logger.error(`[worker-leader] Erreur Redis: ${e?.message} → état préservé (${currentlyLeader ? 'leader' : 'suiveur'})`);
    return currentlyLeader;
  }
}

/**
 * Démarre la boucle d'élection. onBecomeLeader est appelé UNE fois quand cette
 * instance devient leader (pour lancer les jobs). onLoseLeader est appelé si
 * elle perd le leadership (pour arrêter les jobs).
 */
export async function startLeaderElection(
  onBecomeLeader: () => void | Promise<void>,
  onLoseLeader?: () => void | Promise<void>,
): Promise<void> {
  const tick = async () => {
    const nowLeader = await tryAcquireOrRenew(isLeader);
    if (nowLeader && !isLeader) {
      isLeader = true;
      logger.info('[worker-leader] ✅ Activation des jobs de fond (leader)');
      await onBecomeLeader();
    } else if (!nowLeader && isLeader) {
      isLeader = false;
      logger.warn('[worker-leader] ⏸️  Mise en veille des jobs (plus leader)');
      await onLoseLeader?.();
    }
  };

  await tick(); // tentative immédiate au démarrage
  heartbeatTimer = setInterval(() => {
    void tick().catch((e) => logger.error(`[worker-leader] tick échoué: ${e?.message}`));
  }, HEARTBEAT_INTERVAL_MS);
}

/** Libère proprement le leadership à l'arrêt (graceful shutdown). */
export async function releaseLeadership(): Promise<void> {
  if (heartbeatTimer) { clearInterval(heartbeatTimer); heartbeatTimer = null; }
  if (!isLeader) return;
  try {
    if (isRedisConnected()) {
      const redis = await getRedis();
      // Ne supprimer le verrou que si on le détient encore.
      const current = await redis?.get(LEADER_KEY);
      if (current === instanceId) await redis?.del(LEADER_KEY);
    }
  } catch { /* best-effort */ }
  isLeader = false;
  logger.info('[worker-leader] Leadership libéré (shutdown)');
}

export function amILeader(): boolean { return isLeader; }
