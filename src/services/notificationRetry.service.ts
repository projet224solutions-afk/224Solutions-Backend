/**
 * 🔁 RETRY DES NOTIFICATIONS SMS — planificateur + logique partagée.
 * ---------------------------------------------------------------------------
 * Tourne UNIQUEMENT sur le worker (RUN_BACKGROUND_JOBS=true), comme la surveillance,
 * le dropship et les rappels médicaments. Verrou Redis distribué → une seule instance
 * traite la fenêtre (pas de double-envoi entre conteneurs).
 *
 * À chaque tick : retraite les SMS en échec (status='pending', next_retry_at atteint,
 * attempts<3) avec backoff progressif 5min → 15min → 1h. Après 3 échecs : status='failed'.
 * Idempotent : chaque ligne progresse via son compteur attempts ; un re-tick ne renvoie
 * que les lignes encore dues.
 *
 * La même logique (enqueueRetry / processNotificationRetries) est réutilisée par la route
 * POST /api/v2/notifications/process-retries (déclenchement manuel ou cron externe).
 */
import { logger } from '../config/logger.js';
import { locks, isRedisConnected } from '../config/redis.js';
import { supabaseAdmin } from '../config/supabase.js';
import { sendSms } from './sms.service.js';

// Backoff progressif entre tentatives : 5min, 15min, 1h.
export const RETRY_DELAYS = [5 * 60 * 1000, 15 * 60 * 1000, 60 * 60 * 1000];

/** Enfile un SMS échoué dans la file de retry (1ʳᵉ tentative planifiée à +5min). */
export async function enqueueRetry(userId: string, phone: string, message: string): Promise<void> {
  try {
    await supabaseAdmin.from('notification_retry_queue').insert({
      user_id:       userId,
      channel:       'sms',
      recipient:     phone,
      message,
      max_attempts:  3,
      next_retry_at: new Date(Date.now() + RETRY_DELAYS[0]).toISOString(),
      status:        'pending',
    });
  } catch (e) {
    logger.warn(`[notif-retry] enqueue failed: ${(e as Error)?.message}`);
  }
}

/** Retraite jusqu'à 20 SMS en attente dont l'heure de retry est atteinte. */
export async function processNotificationRetries(): Promise<{ processed: number; succeeded: number; failed: number }> {
  const { data: pending } = await supabaseAdmin
    .from('notification_retry_queue')
    .select('*')
    .eq('status', 'pending')
    .lte('next_retry_at', new Date().toISOString())
    .lt('attempts', 3)
    .limit(20);

  if (!pending || pending.length === 0) {
    return { processed: 0, succeeded: 0, failed: 0 };
  }

  let succeeded = 0, failed = 0;
  for (const item of pending) {
    const r = await sendSms(item.recipient, item.message);
    const newAttempts = item.attempts + 1;

    if (r.ok) {
      await supabaseAdmin.from('notification_retry_queue')
        .update({ status: 'succeeded', attempts: newAttempts })
        .eq('id', item.id);
      succeeded++;
    } else {
      const nextDelay = RETRY_DELAYS[newAttempts] || null;
      await supabaseAdmin.from('notification_retry_queue')
        .update({
          attempts:      newAttempts,
          last_error:    r.error || 'Erreur SMS',
          status:        newAttempts >= 3 ? 'failed' : 'pending',
          next_retry_at: nextDelay
            ? new Date(Date.now() + nextDelay).toISOString()
            : new Date().toISOString(),
        })
        .eq('id', item.id);
      failed++;
    }
  }

  logger.info(`[notif-retry] processed=${pending.length} succeeded=${succeeded} failed=${failed}`);
  return { processed: pending.length, succeeded, failed };
}

class NotificationRetryScheduler {
  private interval: ReturnType<typeof setInterval> | null = null;
  private readonly intervalMs: number;

  constructor() {
    this.intervalMs = Number(process.env.NOTIFICATION_RETRY_INTERVAL_MS || 5 * 60_000);
  }

  start(): void {
    if (this.interval) return;
    logger.info(`[NotificationRetry] démarrage (toutes les ${this.intervalMs}ms)`);
    void this.tick('startup');
    this.interval = setInterval(() => void this.tick('interval'), this.intervalMs);
  }

  stop(): void {
    if (!this.interval) return;
    clearInterval(this.interval);
    this.interval = null;
    logger.info('[NotificationRetry] arrêté');
  }

  private async tick(trigger: string): Promise<void> {
    const ttl = Math.max(30, Math.floor(this.intervalMs / 1000) - 5);
    if (isRedisConnected()) {
      const got = await locks.acquire('notifications:sms-retry:tick', ttl);
      if (!got) return; // une autre instance détient la fenêtre
    }
    try {
      await processNotificationRetries();
    } catch (e) {
      logger.warn(`[NotificationRetry] tick ${trigger} erreur: ${(e as Error)?.message}`);
    }
  }
}

export const notificationRetryScheduler = new NotificationRetryScheduler();
