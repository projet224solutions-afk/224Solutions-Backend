/**
 * 📋 JOB QUEUE SYSTEM - Phase 6
 *
 * BullMQ-based async job queue for non-blocking tasks.
 * Falls back to direct execution if Redis unavailable.
 *
 * Supported jobs:
 *   - recommendations.recalculate
 *   - pos.reconcile
 *   - notifications.send
 *   - idempotency.cleanup
 *   - escrow.auto-release
 *   - orders.stuck-alert
 *   - subscriptions.expire-check
 *   - fx.african-rates-refresh
 */

import { Queue, Worker, Job } from 'bullmq';
import { logger } from '../config/logger.js';
import { supabaseAdmin } from '../config/supabase.js';
import { env } from '../config/env.js';
import { collectAfricanRates, refreshBcrgOnly, checkBcrgHeadChanged } from '../services/fxRates.service.js';
import { createNotification } from '../services/notification.service.js';
import { loadServiceAccount, getPrivateBucketName, generateSignedUrl } from '../services/gcs.service.js';
import { dispatchDueScheduledCampaigns } from '../routes/campaigns.routes.js';

const REDIS_JOBS_ENABLED = (process.env.REDIS_ENABLED ?? (env.isProduction ? 'true' : 'false')) === 'true';

// ==================== REDIS CONNECTION (for BullMQ) ====================

const REDIS_CONNECTION = {
  host: process.env.REDIS_HOST || 'localhost',
  port: parseInt(process.env.REDIS_PORT || '6379'),
  password: process.env.REDIS_PASSWORD || undefined,
  maxRetriesPerRequest: null as any,
};

const SYSTEM_USER_ID = '00000000-0000-0000-0000-000000000000';

function isFxSuccessStatus(status: string | null | undefined): boolean {
  const normalized = (status || '').toLowerCase();
  return normalized === 'success' || normalized === 'completed' || normalized === 'ok';
}

async function createFxAlert(params: {
  alertType: string;
  title: string;
  description: string;
  severity: 'medium' | 'high' | 'critical';
  metadata?: Record<string, any>;
  dedupeMinutes?: number;
}) {
  const dedupeMinutes = params.dedupeMinutes ?? 60;
  const dedupeCutoff = new Date(Date.now() - dedupeMinutes * 60 * 1000).toISOString();

  const { data: existing } = await supabaseAdmin
    .from('financial_security_alerts')
    .select('id')
    .eq('alert_type', params.alertType)
    .eq('is_resolved', false)
    .gte('created_at', dedupeCutoff)
    .limit(1)
    .maybeSingle();

  if (existing) {
    return;
  }

  await Promise.resolve(
    supabaseAdmin.from('financial_security_alerts').insert({
      user_id: SYSTEM_USER_ID,
      alert_type: params.alertType,
      severity: params.severity,
      title: params.title,
      description: params.description,
      metadata: params.metadata || {},
    })
  ).catch(() => {});
}

// ==================== JOB REGISTRY ====================

type JobHandler = (data: any) => Promise<void>;
const jobHandlers = new Map<string, JobHandler>();

// ==================== JOB LOGGER (DB) ====================

async function logJobExecution(
  jobName: string,
  queueName: string,
  status: 'started' | 'completed' | 'failed' | 'retrying',
  startedAt: Date,
  attempt: number = 1,
  errorMessage?: string,
  metadata?: any
): Promise<void> {
  try {
    const now = new Date();
    await supabaseAdmin.from('job_execution_log').insert({
      job_name: jobName,
      queue_name: queueName,
      status,
      started_at: startedAt.toISOString(),
      completed_at: status === 'completed' || status === 'failed' ? now.toISOString() : null,
      duration_ms: status === 'completed' || status === 'failed' ? now.getTime() - startedAt.getTime() : null,
      error_message: errorMessage || null,
      metadata: metadata || {},
      attempt,
    });
  } catch (err: any) {
    logger.warn(`Job log write failed: ${err.message}`);
  }
}

// ==================== QUEUES ====================

let mainQueue: Queue | null = null;
let criticalQueue: Queue | null = null;
let mainWorker: Worker | null = null;
let criticalWorker: Worker | null = null;
let recurringTimers: Array<ReturnType<typeof setInterval>> = [];

function createQueue(name: string): Queue | null {
  try {
    return new Queue(name, { connection: REDIS_CONNECTION, defaultJobOptions: {
      attempts: 3,
      backoff: { type: 'exponential', delay: 2000 },
      removeOnComplete: { age: 86400 }, // 24h
      removeOnFail: { age: 7 * 86400 }, // 7 days
    }});
  } catch (err: any) {
    logger.warn(`Queue creation failed (${name}): ${err.message}`);
    return null;
  }
}

function createWorker(queueName: string, concurrency: number = 3): Worker | null {
  try {
    const worker = new Worker(queueName, async (job: Job) => {
      const handler = jobHandlers.get(job.name);
      if (!handler) {
        logger.warn(`No handler for job: ${job.name}`);
        return;
      }

      const startedAt = new Date();
      await logJobExecution(job.name, queueName, 'started', startedAt, job.attemptsMade + 1);

      try {
        await handler(job.data);
        await logJobExecution(job.name, queueName, 'completed', startedAt, job.attemptsMade + 1);
        logger.info(`Job completed: ${job.name} (${job.id})`);
      } catch (err: any) {
        const isLastAttempt = job.attemptsMade + 1 >= (job.opts.attempts || 3);
        await logJobExecution(
          job.name, queueName,
          isLastAttempt ? 'failed' : 'retrying',
          startedAt, job.attemptsMade + 1,
          err.message, job.data
        );
        throw err; // BullMQ handles retry
      }
    }, { connection: REDIS_CONNECTION, concurrency });

    worker.on('failed', (job, err) => {
      logger.error(`Job failed: ${job?.name} (${job?.id}) — ${err.message}`);
    });

    return worker;
  } catch (err: any) {
    logger.warn(`Worker creation failed (${queueName}): ${err.message}`);
    return null;
  }
}

// ==================== REGISTER JOB HANDLERS ====================

function registerHandler(name: string, handler: JobHandler): void {
  jobHandlers.set(name, handler);
}

// ==================== JOB DEFINITIONS ====================

registerHandler('idempotency.cleanup', async () => {
  const cutoff = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  const { error, count } = await supabaseAdmin
    .from('idempotency_keys')
    .delete()
    .lt('expires_at', cutoff);
  logger.info(`Idempotency cleanup: deleted ${count || 0} expired keys`);
});

// Purge des preuves de livraison 7 jours APRÈS la confirmation de réception du client :
// supprime les fichiers du bucket privé + efface les chemins en base (RGPD/rétention courte).
registerHandler('delivery-proof.cleanup', async () => {
  const cutoff = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString();
  const { data: orders, error } = await supabaseAdmin
    .from('orders')
    .select('id, delivery_proof_photo_path, delivery_proof_video_path')
    .lt('delivery_confirmed_at', cutoff)
    .is('delivery_proof_purged_at', null)
    .not('delivery_proof_photo_path', 'is', null)
    .limit(200);
  if (error) { logger.error(`[delivery-proof.cleanup] ${error.message}`); return; }
  if (!orders?.length) { logger.info('Delivery proof cleanup: rien à purger'); return; }

  let purged = 0;
  for (const o of orders as any[]) {
    // Séparer les chemins GCS privé (préfixe « gcs: ») des chemins Supabase (héritage).
    const supabasePaths: string[] = [];
    const gcsPaths: string[] = [];
    for (const p of [o.delivery_proof_photo_path, o.delivery_proof_video_path]) {
      if (!p) continue;
      if (String(p).startsWith('gcs:')) gcsPaths.push(String(p).slice(4));
      else supabasePaths.push(p);
    }
    let delOk = true;
    if (supabasePaths.length) {
      const { error: delErr } = await supabaseAdmin.storage.from('delivery-proofs').remove(supabasePaths);
      if (delErr) { logger.error(`[delivery-proof.cleanup] supabase ${o.id}: ${delErr.message}`); delOk = false; }
    }
    if (gcsPaths.length) {
      const sa = loadServiceAccount();
      if (!sa) { logger.error(`[delivery-proof.cleanup] GCS non configuré, purge ${o.id} différée`); delOk = false; }
      else {
        for (const op of gcsPaths) {
          try {
            const url = generateSignedUrl(sa, getPrivateBucketName(), op, { method: 'DELETE', expiresInSeconds: 120 });
            const r = await fetch(url, { method: 'DELETE' });
            if (!(r.ok || r.status === 404)) { logger.error(`[delivery-proof.cleanup] GCS ${o.id}: HTTP ${r.status}`); delOk = false; }
          } catch (e: any) { logger.error(`[delivery-proof.cleanup] GCS ${o.id}: ${e?.message}`); delOk = false; }
        }
      }
    }
    if (!delOk) continue; // ne pas marquer purgé si la suppression a échoué (réessai prochain run)
    const { error: updErr } = await supabaseAdmin.from('orders').update({
      delivery_proof_photo_path: null,
      delivery_proof_video_path: null,
      delivery_proof_purged_at: new Date().toISOString(),
    } as any).eq('id', o.id);
    if (updErr) { logger.error(`[delivery-proof.cleanup] db ${o.id}: ${updErr.message}`); continue; }
    purged++;
  }
  logger.info(`Delivery proof cleanup: ${purged}/${orders.length} purgées`);
});

registerHandler('escrow.auto-release', async () => {
  const now = new Date().toISOString();
  const { data: escrows } = await supabaseAdmin
    .from('escrow_transactions')
    .select('id, order_id, seller_id, amount, currency, commission_amount, metadata, seller_confirmed_at, orders(id, order_number, status, payment_method, shipping_address, metadata)')
    .eq('status', 'held')
    .not('seller_confirmed_at', 'is', null)
    .lt('auto_release_date', now)
    .is('dispute_status', null);

  if (!escrows?.length) return;

  for (const escrow of escrows) {
    try {
      const order = Array.isArray((escrow as any).orders) ? (escrow as any).orders[0] : (escrow as any).orders;
      const orderMetadata =
        order?.metadata && typeof order.metadata === 'object' && !Array.isArray(order.metadata)
          ? order.metadata
          : {};
      const shippingAddress =
        order?.shipping_address && typeof order.shipping_address === 'object' && !Array.isArray(order.shipping_address)
          ? order.shipping_address
          : {};
      const isCashOnDelivery =
        order?.payment_method === 'cash' &&
        (orderMetadata.is_cod === true || shippingAddress.is_cod === true || orderMetadata.payment_type === 'cash_on_delivery');

      if (
        !order ||
        !escrow.seller_confirmed_at ||
        isCashOnDelivery ||
        ['pending', 'cancelled', 'completed'].includes(order.status) ||
        orderMetadata.buyer_confirmed_delivery === true
      ) {
        continue;
      }

      // 🧱 Libération via la PRIMITIVE CANONIQUE (FOR UPDATE + idempotente + conversion + atomique).
      // Crédit vendeur (converti) + commission PDG + ligne d'historique + statut escrow, en 1 transaction.
      const { data: relData, error: relErr } = await supabaseAdmin.rpc('release_escrow_to_seller', {
        p_escrow_id: escrow.id,
        p_reason: 'buyer_confirmation_timeout_48h',
      });
      if (relErr) throw new Error(relErr.message);
      if (relData && (relData as any).success === false) throw new Error((relData as any).error || 'release failed');

      // Marquer la commande complétée (la primitive ne touche pas la commande)
      await supabaseAdmin
        .from('orders')
        .update({
          status: 'completed',
          metadata: {
            ...orderMetadata,
            delivered_at: orderMetadata.delivered_at || now,
            auto_confirmed_reception: true,
            auto_confirmed_reception_at: now,
            buyer_confirmation_timeout_hours: 48,
          },
          updated_at: now,
        })
        .eq('id', escrow.order_id);

      logger.info(`Escrow auto-released via primitive: ${escrow.id} — ${JSON.stringify(relData)}`);
    } catch (err: any) {
      logger.error(`Escrow release failed: ${escrow.id} — ${err.message}`);
    }
  }
});

// 🤝 AFFILIATION NUMÉRIQUE : confirme + paie les commissions des commandes NUMÉRIQUES payées,
// passé la fenêtre de protection acheteur (48h) et tant que la commande n'est pas annulée/remboursée.
// (Les produits numériques n'ont pas d'escrow → confirmation pilotée par ce job, idempotent.)
registerHandler('affiliate.confirm-digital', async () => {
  const protectionCutoff = new Date(Date.now() - 48 * 3600000).toISOString();
  const { data: pending } = await supabaseAdmin
    .from('affiliate_commissions')
    .select('order_id')
    .eq('status', 'pending')
    .lt('created_at', protectionCutoff)
    .limit(500);
  if (!pending?.length) return;

  const orderIds = [...new Set(pending.map((c: any) => c.order_id).filter(Boolean))];
  if (!orderIds.length) return;

  // Ne confirmer que les commandes encore PAYÉES et NON annulées/remboursées.
  const { data: orders } = await supabaseAdmin
    .from('orders')
    .select('id, status, payment_status')
    .in('id', orderIds);
  const eligible = (orders || []).filter(
    (o: any) => o.payment_status === 'paid' && !['cancelled', 'refunded'].includes(o.status)
  );

  for (const order of eligible) {
    const { error } = await supabaseAdmin.rpc('confirm_affiliate_commissions', { p_order_id: order.id });
    if (error) {
      // INSUFFICIENT_FUNDS (vendeur) → on réessaiera au prochain passage. Non bloquant.
      logger.warn(`[affiliate] confirm-digital ${order.id}: ${error.message}`);
    } else {
      logger.info(`[affiliate] commissions confirmées (commande numérique ${order.id})`);
    }
  }
});

// 🧹 224Guard : auto-résolution des erreurs ÉTEINTES — une famille (même error_message)
// sans AUCUNE réapparition depuis 7 jours = bug corrigé → 'resolved'. Sans ce job, les
// compteurs du Command Center cumulaient l'historique (ex. « 50 critiques » dont 0 active)
// et fabriquaient de fausses urgences à chaque rapport IA. Les familles actives sont intactes.
registerHandler('errors.auto-resolve-stale', async () => {
  const STALE_DAYS = 7;
  const cutoff = new Date(Date.now() - STALE_DAYS * 86400000).toISOString();
  const { data: detected } = await supabaseAdmin
    .from('system_errors')
    .select('id, error_message, created_at')
    .eq('status', 'detected')
    .order('created_at', { ascending: false })
    .limit(1000);
  if (!detected?.length) return;

  // Famille = error_message ; éteinte si sa DERNIÈRE occurrence est plus vieille que le cutoff.
  const families = new Map<string, { last: string; ids: string[] }>();
  for (const e of detected as any[]) {
    const k = e.error_message || '(vide)';
    const f = families.get(k) || { last: e.created_at, ids: [] };
    if (e.created_at > f.last) f.last = e.created_at;
    f.ids.push(e.id);
    families.set(k, f);
  }

  let resolved = 0;
  for (const [, f] of families) {
    if (f.last >= cutoff) continue; // famille encore active → on n'y touche pas
    for (let i = 0; i < f.ids.length; i += 100) {
      const { error } = await supabaseAdmin
        .from('system_errors')
        .update({
          status: 'resolved',
          fixed_at: new Date().toISOString(),
          fix_description: `Auto-résolue : famille éteinte depuis > ${STALE_DAYS} j (aucune réapparition)`,
        })
        .in('id', f.ids.slice(i, i + 100));
      if (error) { logger.warn(`[errors] auto-resolve-stale: ${error.message}`); return; }
      resolved += Math.min(100, f.ids.length - i);
    }
  }
  if (resolved > 0) logger.info(`[errors] auto-resolve-stale: ${resolved} erreur(s) éteinte(s) résolue(s)`);
});

// ☎️ Appels : filet « pas de réponse » — tout appel resté 'ringing' > 60 s passe en 'missed'
// via la RPC expire_stale_ringing_calls (migration 20260703130000). Doublonne volontairement
// le pg_cron éventuel : la RPC est idempotente, deux exécutions/minute sont sans effet de bord.
registerHandler('calls.expire-ringing', async () => {
  const { error } = await supabaseAdmin.rpc('expire_stale_ringing_calls' as any);
  if (error) logger.warn(`[calls] expire-ringing: ${error.message}`);
});

// Restaurant : annule + rembourse (atomique) les commandes payées mais NON acceptées après 3 min.
registerHandler('restaurant.auto-cancel', async () => {
  const cutoff = new Date(Date.now() - 3 * 60 * 1000).toISOString();
  const { data: stale } = await supabaseAdmin
    .from('restaurant_orders')
    .select('id')
    .eq('status', 'pending')
    .eq('payment_status', 'paid')
    .lt('created_at', cutoff)
    .limit(100);
  if (!stale?.length) return;
  let cancelled = 0;
  for (const o of stale) {
    try {
      await supabaseAdmin.rpc('cancel_restaurant_order', { p_order_id: (o as any).id, p_reason: 'auto_timeout_3min' });
      cancelled++;
    } catch (err: any) {
      logger.warn(`[restaurant.auto-cancel] ${(o as any).id} — ${err?.message}`);
    }
  }
  logger.info(`[restaurant.auto-cancel] ${cancelled}/${stale.length} commande(s) expirée(s) remboursée(s)`);
});

// Campagnes PROGRAMMÉES : envoie celles arrivées à échéance (status='scheduled', scheduled_at <= now()).
// Idempotent + safe multi-instance : chaque campagne est « claimée » par un UPDATE conditionnel de statut.
registerHandler('campaigns.dispatch-scheduled', async () => {
  const { due, dispatched } = await dispatchDueScheduledCampaigns(50);
  if (due > 0) logger.info(`[campaigns.dispatch-scheduled] ${dispatched}/${due} campagne(s) programmée(s) lancée(s)`);
});

registerHandler('subscriptions.expire-check', async () => {
  const now = new Date().toISOString();

  // 1. Abonnements VENDEUR (subscriptions.current_period_end)
  const { data: vend } = await supabaseAdmin
    .from('subscriptions')
    .update({ status: 'expired' })
    .in('status', ['active', 'trialing', 'past_due'])
    .lt('current_period_end', now)
    .select('id');

  // 2. Abonnements CHAUFFEUR (driver_subscriptions.end_date) — n'étaient JAMAIS expirés (fuite)
  const { data: drv } = await supabaseAdmin
    .from('driver_subscriptions')
    .update({ status: 'expired', updated_at: now })
    .eq('status', 'active')
    .lt('end_date', now)
    .select('id');

  // 3. Abonnements SERVICE (service_subscriptions.current_period_end) — idem
  const { data: svc } = await supabaseAdmin
    .from('service_subscriptions')
    .update({ status: 'expired', updated_at: now })
    .eq('status', 'active')
    .lt('current_period_end', now)
    .select('id');

  logger.info(`Subscriptions expired — vendeur:${vend?.length || 0} chauffeur:${drv?.length || 0} service:${svc?.length || 0}`);
});

// Rappels d'expiration J-3 / J-1 (abonnements service). Notif in-app idempotente par paliers
// NON chevauchants (J-3 = expire dans 2-3 j ; J-1 = expire dans 0-1 j) + cadence 24h ⇒ ~1 envoi/palier.
registerHandler('subscriptions.expiry-reminders', async () => {
  const now = Date.now();
  const at = (days: number) => new Date(now + days * 86_400_000).toISOString();
  const buckets = [
    { label: 'J-3', when: 'dans 3 jours', from: at(2), to: at(3) },
    { label: 'J-1', when: 'demain', from: at(0), to: at(1) },
  ];
  let sent = 0;
  for (const b of buckets) {
    const { data: subs } = await supabaseAdmin
      .from('service_subscriptions')
      .select('user_id, current_period_end, service_plans(display_name)')
      .eq('status', 'active')
      .gt('current_period_end', b.from)
      .lte('current_period_end', b.to);
    for (const s of (subs as any[]) || []) {
      const plan = s.service_plans?.display_name || 'Votre abonnement';
      const ok = await createNotification({
        userId: s.user_id,
        title: 'Abonnement bientôt expiré',
        message: `${plan} expire ${b.when}. Renouvelez pour conserver vos avantages.`,
        type: 'subscription_expiry',
        metadata: { reminder: b.label, period_end: s.current_period_end },
      });
      if (ok) sent++;
    }
  }
  logger.info(`Subscription expiry reminders sent: ${sent}`);
});

// Rappels BEAUTÉ : J-1 (la veille) et H-2 (dans ~2h) pour les RDV confirmés.
registerHandler('beauty.reminders', async () => {
  let sent = 0;
  const todayStr = new Date().toISOString().slice(0, 10);
  const tomorrowStr = new Date(Date.now() + 86_400_000).toISOString().slice(0, 10);

  // J-1 : RDV de demain non encore rappelés.
  const { data: dayBefore } = await supabaseAdmin
    .from('beauty_appointments')
    .select('id, customer_user_id, appointment_time, professional_service_id, professional_services(business_name)')
    .eq('appointment_date', tomorrowStr).eq('status', 'confirmed').eq('reminder_day_before_sent', false);
  for (const a of (dayBefore as any[]) || []) {
    if (a.customer_user_id) {
      await createNotification({
        userId: a.customer_user_id, title: 'Rappel rendez-vous',
        message: `Vous avez un RDV demain à ${String(a.appointment_time).slice(0, 5)} chez ${a.professional_services?.business_name || 'votre salon'}.`,
        type: 'beauty_reminder', metadata: { appointment_id: a.id, kind: 'J-1' },
      });
      sent++;
    }
    await supabaseAdmin.from('beauty_appointments').update({ reminder_day_before_sent: true }).eq('id', a.id);
  }

  // H-2 : RDV d'aujourd'hui dans la fenêtre [now+1h45, now+2h30].
  const now = new Date();
  const lo = new Date(now.getTime() + 105 * 60000).toTimeString().slice(0, 8);
  const hi = new Date(now.getTime() + 150 * 60000).toTimeString().slice(0, 8);
  const { data: soon } = await supabaseAdmin
    .from('beauty_appointments')
    .select('id, customer_user_id, appointment_time, professional_services(business_name)')
    .eq('appointment_date', todayStr).eq('status', 'confirmed').eq('reminder_2h_sent', false)
    .gte('appointment_time', lo).lte('appointment_time', hi);
  for (const a of (soon as any[]) || []) {
    if (a.customer_user_id) {
      await createNotification({
        userId: a.customer_user_id, title: 'RDV dans 2h',
        message: `Votre RDV chez ${a.professional_services?.business_name || 'votre salon'} est à ${String(a.appointment_time).slice(0, 5)}.`,
        type: 'beauty_reminder', metadata: { appointment_id: a.id, kind: 'H-2' },
      });
      sent++;
    }
    await supabaseAdmin.from('beauty_appointments').update({ reminder_2h_sent: true }).eq('id', a.id);
  }
  logger.info(`Beauty reminders sent: ${sent}`);
});

// Achats groupés expirés sans minimum → remboursement automatique de tous les participants.
registerHandler('group-buys.finalize-expired', async () => {
  const { data, error } = await supabaseAdmin.rpc('finalize_expired_group_buys');
  if (error) { logger.warn(`[group-buys] finalize: ${error.message}`); return; }
  if (data) logger.info(`Group-buys expirés finalisés (remboursés): ${data}`);
});

registerHandler('orders.stuck-alert', async () => {
  const stuckThreshold = new Date(Date.now() - 48 * 60 * 60 * 1000).toISOString();
  const { data: stuck } = await supabaseAdmin
    .from('orders')
    .select('id, order_number, status, created_at')
    .eq('status', 'pending')
    .lt('created_at', stuckThreshold)
    .limit(50);

  if (stuck?.length) {
    logger.warn(`Stuck orders detected: ${stuck.length}`, { orderIds: stuck.map(o => o.id) });
    // Could send admin notification here
  }
});

registerHandler('pos.reconcile', async () => {
  // P0 OPTIMIZED: Uses decrement_stock_batch for batch processing
  const { data: pending } = await supabaseAdmin
    .from('pos_stock_reconciliation')
    .select('id, product_id, expected_decrement, retry_count, max_retries')
    .eq('status', 'pending')
    .limit(100);

  if (!pending?.length) return;

  const now = new Date().toISOString();

  // Group by similar items for batch processing
  const batchItems = pending.map(rec => ({
    product_id: rec.product_id,
    quantity: rec.expected_decrement,
  }));

  const { data: batchResult, error: batchError } = await supabaseAdmin.rpc('decrement_stock_batch', {
    p_items: batchItems,
  });

  if (!batchError && batchResult?.success) {
    // All succeeded — mark all as resolved
    const ids = pending.map(r => r.id);
    await supabaseAdmin
      .from('pos_stock_reconciliation')
      .update({ status: 'resolved', resolved_at: now, last_retry_at: now })
      .in('id', ids);

    logger.info(`POS reconciliation: ${pending.length}/${pending.length} resolved (batch)`);
  } else {
    // Batch failed — fall back to individual retries
    const errorMsg = batchError?.message || batchResult?.error || 'Batch failed';
    let fixed = 0;

    for (const rec of pending) {
      try {
        await supabaseAdmin.rpc('decrement_product_stock', {
          p_product_id: rec.product_id,
          p_quantity: rec.expected_decrement,
        });

        await supabaseAdmin
          .from('pos_stock_reconciliation')
          .update({ status: 'resolved', resolved_at: now, last_retry_at: now })
          .eq('id', rec.id);

        fixed++;
      } catch (err: any) {
        const newRetry = (rec.retry_count || 0) + 1;
        const maxRetries = rec.max_retries || 5;

        await supabaseAdmin
          .from('pos_stock_reconciliation')
          .update({
            retry_count: newRetry,
            last_retry_at: now,
            status: newRetry >= maxRetries ? 'failed' : 'pending',
            error_message: err.message,
          })
          .eq('id', rec.id);

        logger.warn(`POS reconcile retry failed: ${rec.id} (attempt ${newRetry}/${maxRetries}) — ${err.message}`);
      }
    }
    logger.info(`POS reconciliation: ${fixed}/${pending.length} resolved (fallback)`);
  }
});

registerHandler('recommendations.recalculate', async () => {
  // Aligned with real schema:
  //   user_activity.action_type (NOT activity_type)
  //   product_scores columns: views_count, clicks_count, cart_count,
  //     purchases_count, total_score, trending_score, conversion_rate,
  //     is_featured, last_computed
  // Weights match useSmartRecommendations.ts engine
  const ACTION_WEIGHTS: Record<string, number> = {
    purchase: 5,
    add_to_cart: 3,
    click: 2,
    view: 1,
  };

  const cutoff = new Date(Date.now() - 7 * 86400000).toISOString();

  // Fetch recent activity — real column is action_type
  const { data: activities } = await supabaseAdmin
    .from('user_activity')
    .select('product_id, action_type')
    .gte('created_at', cutoff)
    .not('product_id', 'is', null)
    .limit(10000);

  if (!activities?.length) {
    logger.info('Recommendations recalculate: no recent activity');
    return;
  }

  // Aggregate counts per product per action_type
  const productStats = new Map<string, { views: number; clicks: number; carts: number; purchases: number }>();

  for (const act of activities) {
    if (!act.product_id) continue;
    const stats = productStats.get(act.product_id) || { views: 0, clicks: 0, carts: 0, purchases: 0 };

    switch (act.action_type) {
      case 'view': stats.views++; break;
      case 'click': stats.clicks++; break;
      case 'add_to_cart': stats.carts++; break;
      case 'purchase': stats.purchases++; break;
      default: stats.views++; // fallback
    }

    productStats.set(act.product_id, stats);
  }

  // Upsert into product_scores with real columns
  const now = new Date().toISOString();
  let updated = 0;

  for (const [productId, stats] of productStats) {
    const totalScore =
      stats.views * ACTION_WEIGHTS.view +
      stats.clicks * ACTION_WEIGHTS.click +
      stats.carts * ACTION_WEIGHTS.add_to_cart +
      stats.purchases * ACTION_WEIGHTS.purchase;

    const conversionRate = stats.views > 0 ? stats.purchases / stats.views : 0;

    try {
      await supabaseAdmin
        .from('product_scores')
        .upsert({
          product_id: productId,
          views_count: stats.views,
          clicks_count: stats.clicks,
          cart_count: stats.carts,
          purchases_count: stats.purchases,
          total_score: totalScore,
          trending_score: totalScore, // same as total for 7-day window
          conversion_rate: Math.round(conversionRate * 10000) / 10000,
          last_computed: now,
        }, { onConflict: 'product_id' });
      updated++;
    } catch { /* continue */ }
  }

  logger.info(`Recommendations recalculated: ${updated} products scored from ${activities.length} activities`);
});

registerHandler('payment-links.cleanup-expired', async () => {
  const now = new Date().toISOString();
  const { data: expired, error } = await supabaseAdmin
    .from('payment_links')
    .update({ status: 'expired' })
    .eq('status', 'pending')
    .lt('expires_at', now)
    .select('id, payment_id');

  if (error) {
    logger.warn(`Payment links cleanup failed: ${error.message}`);
  } else if (expired?.length) {
    logger.info(`Payment links cleanup: marked ${expired.length} links as expired`);
  }
});

registerHandler('fx.african-rates-refresh', async () => {
  let result: Awaited<ReturnType<typeof collectAfricanRates>>;

  try {
    result = await collectAfricanRates();
  } catch (err: any) {
    await createFxAlert({
      alertType: 'fx_collection_failed',
      severity: 'high',
      title: 'Échec collecte FX horaire',
      description: `La collecte horaire des taux a échoué: ${err.message}`,
      metadata: { error: err.message },
      dedupeMinutes: 30,
    });
    throw err;
  }

  if (result.failed > 0 && result.ok === 0) {
    await createFxAlert({
      alertType: 'fx_collection_failed',
      severity: 'high',
      title: 'Échec collecte FX horaire',
      description: `Aucun taux collecté. Échecs: ${result.failed}, durée: ${result.durationMs}ms`,
      metadata: { failed: result.failed, ok: result.ok, fallback: result.fallback, durationMs: result.durationMs },
      dedupeMinutes: 30,
    });
  }

  const { data: latestRate } = await supabaseAdmin
    .from('currency_exchange_rates')
    .select('retrieved_at')
    .eq('is_active', true)
    .order('retrieved_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  const now = Date.now();
  const lastRetrievedAt = latestRate?.retrieved_at ? new Date(latestRate.retrieved_at).getTime() : 0;
  const ageMinutes = lastRetrievedAt ? Math.floor((now - lastRetrievedAt) / 60000) : 9999;
  if (ageMinutes > 90) {
    await createFxAlert({
      alertType: 'fx_rates_stale',
      severity: 'critical',
      title: 'Taux FX obsolètes',
      description: `Les taux ne sont pas à jour depuis ${ageMinutes} minutes (>90).`,
      metadata: { age_minutes: ageMinutes, threshold_minutes: 90 },
      dedupeMinutes: 60,
    });
  }

  const { data: recentGnfRuns } = await supabaseAdmin
    .from('fx_collection_log')
    .select('status, collected_at, error_message')
    .eq('currency_code', 'GNF')
    .order('collected_at', { ascending: false })
    .limit(2);

  const twoConsecutiveFailures = (recentGnfRuns || []).length >= 2
    && (recentGnfRuns || []).every((run) => !isFxSuccessStatus(run.status));

  if (twoConsecutiveFailures) {
    await createFxAlert({
      alertType: 'fx_two_consecutive_failures',
      severity: 'critical',
      title: 'Collecte FX en échec consécutif',
      description: 'Deux collectes consécutives ont échoué pour GNF.',
      metadata: { recent_runs: recentGnfRuns },
      dedupeMinutes: 60,
    });
  }

  logger.info('African FX rates refreshed from official sources', {
    ok: result.ok,
    fallback: result.fallback,
    cached: result.cached,
    failed: result.failed,
    durationMs: result.durationMs,
  });
});

// Surveillance BCRG temps réel — HEAD check d'abord, GET complet seulement si la page a changé
registerHandler('fx.bcrg-live-check', async () => {
  try {
    const pageChanged = await checkBcrgHeadChanged();
    if (!pageChanged) return; // Page identique → pas besoin de scraper
    const result = await refreshBcrgOnly();
    if (result.changed) {
      logger.info(`[BCRG-LIVE] Taux modifiés: ${result.changedPairs.join(', ')} | USD/GNF=${result.usdGnf} (${result.durationMs}ms)`);
    }
  } catch (err: any) {
    logger.warn(`[BCRG-LIVE] Échec surveillance: ${err.message}`);
  }
});

// ==================== PUBLIC API ====================

export const jobQueue = {
  /**
   * Initialize queues and workers. Call once at app startup.
   */
  async init(): Promise<void> {
    if (!REDIS_JOBS_ENABLED) {
      logger.info('Job queues disabled (REDIS_ENABLED=false), using direct execution fallback');
      return;
    }

    try {
      mainQueue = createQueue('main');
      criticalQueue = createQueue('critical');
      mainWorker = createWorker('main', 3);
      criticalWorker = createWorker('critical', 5);

      if (mainQueue && criticalQueue) {
        logger.info('✅ Job queues initialized (main + critical)');
      } else {
        logger.warn('⚠️ Job queues not available, will use direct execution');
      }
    } catch (err: any) {
      logger.warn(`Job queue init failed: ${err.message}, using fallback`);
    }
  },

  /**
   * Enqueue a job. Falls back to direct execution if queues unavailable.
   */
  async enqueue(jobName: string, data: any = {}, options?: { priority?: boolean; delay?: number }): Promise<void> {
    const queue = options?.priority ? criticalQueue : mainQueue;

    if (queue) {
      try {
        await queue.add(jobName, data, {
          delay: options?.delay,
          priority: options?.priority ? 1 : undefined,
        });
        logger.info(`Job enqueued: ${jobName}`);
        return;
      } catch (err: any) {
        logger.warn(`Job enqueue failed, executing directly: ${err.message}`);
      }
    }

    // Fallback: direct execution (non-blocking)
    const handler = jobHandlers.get(jobName);
    if (handler) {
      const startedAt = new Date();
      handler(data)
        .then(() => logJobExecution(jobName, 'direct', 'completed', startedAt))
        .catch((err) => {
          logger.error(`Direct job failed: ${jobName} — ${err.message}`);
          logJobExecution(jobName, 'direct', 'failed', startedAt, 1, err.message);
        });
    } else {
      logger.warn(`No handler for job: ${jobName}`);
    }
  },

  /**
   * Exécute un job MAINTENANT et ATTEND son résultat (déclenchement manuel/remédiation PDG).
   * Contrairement à enqueue (fire-and-forget), renvoie { ok, error } pour tracer l'application.
   */
  async runNow(jobName: string, data: any = {}): Promise<{ ok: boolean; error?: string }> {
    const handler = jobHandlers.get(jobName);
    if (!handler) return { ok: false, error: `Aucun handler pour le job ${jobName}` };
    const startedAt = new Date();
    try {
      await handler(data);
      logJobExecution(jobName, 'manual', 'completed', startedAt);
      return { ok: true };
    } catch (err: any) {
      logger.error(`Manual job failed: ${jobName} — ${err?.message}`);
      logJobExecution(jobName, 'manual', 'failed', startedAt, 1, err?.message);
      return { ok: false, error: err?.message || 'Échec du job' };
    }
  },

  /**
   * Schedule recurring jobs. Call once at startup.
   */
  async scheduleRecurring(): Promise<void> {
    if (!env.ENABLE_CRON_JOBS) {
      logger.info('Recurring jobs disabled by ENABLE_CRON_JOBS=false');
      return;
    }

    if (!REDIS_JOBS_ENABLED) {
      logger.info('Recurring jobs using in-process fallback scheduler (Redis disabled)');

      const everyHour = 3600000;
      const every6Hours = 6 * 3600000;
      const every24Hours = 24 * 3600000;

      // Trigger FX immediately on startup to avoid missing today's first rate.
      this.enqueue('fx.african-rates-refresh', {}).catch(() => {});
      this.enqueue('fx.bcrg-live-check', {}).catch(() => {});

      recurringTimers.push(setInterval(() => this.enqueue('idempotency.cleanup', {}).catch(() => {}), everyHour));
      recurringTimers.push(setInterval(() => this.enqueue('orders.stuck-alert', {}).catch(() => {}), everyHour));
      recurringTimers.push(setInterval(() => this.enqueue('payment-links.cleanup-expired', {}).catch(() => {}), everyHour));
      recurringTimers.push(setInterval(() => this.enqueue('group-buys.finalize-expired', {}).catch(() => {}), everyHour));
      recurringTimers.push(setInterval(() => this.enqueue('fx.african-rates-refresh', {}).catch(() => {}), everyHour));
      // Surveillance BCRG toutes les 1 minute — HEAD check léger, GET uniquement si changement
      recurringTimers.push(setInterval(() => this.enqueue('fx.bcrg-live-check', {}).catch(() => {}), 60 * 1000));
      // Restaurant : annulation auto + remboursement des commandes non acceptées en 3 min (check toutes les 60s)
      recurringTimers.push(setInterval(() => this.enqueue('restaurant.auto-cancel', {}).catch(() => {}), 60 * 1000));
      // Campagnes programmées : check toutes les 60s pour lancer celles arrivées à échéance
      recurringTimers.push(setInterval(() => this.enqueue('campaigns.dispatch-scheduled', {}).catch(() => {}), 60 * 1000));
      // Appels : ringing > 60s → missed (filet serveur, RPC idempotente)
      recurringTimers.push(setInterval(() => this.enqueue('calls.expire-ringing', {}).catch(() => {}), 60 * 1000));

      recurringTimers.push(setInterval(() => this.enqueue('escrow.auto-release', {}).catch(() => {}), every6Hours));
      recurringTimers.push(setInterval(() => this.enqueue('affiliate.confirm-digital', {}).catch(() => {}), every6Hours));
      recurringTimers.push(setInterval(() => this.enqueue('subscriptions.expire-check', {}).catch(() => {}), every6Hours));
      recurringTimers.push(setInterval(() => this.enqueue('pos.reconcile', {}).catch(() => {}), every6Hours));

      recurringTimers.push(setInterval(() => this.enqueue('recommendations.recalculate', {}).catch(() => {}), every24Hours));
      recurringTimers.push(setInterval(() => this.enqueue('subscriptions.expiry-reminders', {}).catch(() => {}), every24Hours));
      // Purge quotidienne des preuves de livraison 7 j après confirmation de réception (RGPD)
      recurringTimers.push(setInterval(() => this.enqueue('delivery-proof.cleanup', {}).catch(() => {}), every24Hours));
      // 224Guard : erreurs éteintes > 7j → resolved (compteurs Command Center fiables)
      recurringTimers.push(setInterval(() => this.enqueue('errors.auto-resolve-stale', {}).catch(() => {}), every24Hours));
      // Rappels beauté J-1/H-2 toutes les 15 minutes
      recurringTimers.push(setInterval(() => this.enqueue('beauty.reminders', {}).catch(() => {}), 15 * 60 * 1000));

      logger.info('✅ In-process recurring jobs scheduled');
      return;
    }

    const queue = mainQueue;
    if (!queue) {
      logger.warn('Recurring jobs not scheduled: no queue available');
      return;
    }

    try {
      // Every hour: cleanup + stuck orders
      await queue.add('idempotency.cleanup', {}, { repeat: { every: 3600000 } });
      await queue.add('orders.stuck-alert', {}, { repeat: { every: 3600000 } });
      await queue.add('payment-links.cleanup-expired', {}, { repeat: { every: 3600000 } });
      await queue.add('group-buys.finalize-expired', {}, { repeat: { every: 3600000 } });
      await queue.add('fx.african-rates-refresh', {}, { repeat: { every: 3600000 } });
      // Surveillance BCRG toutes les 1 minute — HEAD check léger, GET uniquement si changement
      await queue.add('fx.bcrg-live-check', {}, { repeat: { every: 60 * 1000 } });
      // Restaurant : annulation auto 3 min des commandes non acceptées (check toutes les 60s)
      await queue.add('restaurant.auto-cancel', {}, { repeat: { every: 60 * 1000 } });
      // Campagnes programmées : lancement automatique à l'échéance (check toutes les 60s)
      await queue.add('campaigns.dispatch-scheduled', {}, { repeat: { every: 60 * 1000 } });
      // Appels : ringing > 60s → missed (filet serveur, RPC idempotente)
      await queue.add('calls.expire-ringing', {}, { repeat: { every: 60 * 1000 } });

      // Every 6 hours: escrow + subscriptions + POS
      await queue.add('escrow.auto-release', {}, { repeat: { every: 6 * 3600000 } });
      await queue.add('affiliate.confirm-digital', {}, { repeat: { every: 6 * 3600000 } });
      await queue.add('subscriptions.expire-check', {}, { repeat: { every: 6 * 3600000 } });
      await queue.add('pos.reconcile', {}, { repeat: { every: 6 * 3600000 } });

      // Daily: recommendations + rappels d'expiration d'abonnement
      await queue.add('recommendations.recalculate', {}, { repeat: { every: 24 * 3600000 } });
      await queue.add('subscriptions.expiry-reminders', {}, { repeat: { every: 24 * 3600000 } });
      // Purge quotidienne des preuves de livraison 7 j après confirmation de réception (RGPD)
      await queue.add('delivery-proof.cleanup', {}, { repeat: { every: 24 * 3600000 } });
      // 224Guard : erreurs éteintes > 7j → resolved (compteurs Command Center fiables)
      await queue.add('errors.auto-resolve-stale', {}, { repeat: { every: 24 * 3600000 } });
      await queue.add('beauty.reminders', {}, { repeat: { every: 15 * 60 * 1000 } });

      logger.info('✅ Recurring jobs scheduled');
    } catch (err: any) {
      logger.warn(`Recurring job scheduling failed: ${err.message}`);
    }
  },

  /**
   * Graceful shutdown.
   */
  async shutdown(): Promise<void> {
    recurringTimers.forEach((timer) => clearInterval(timer));
    recurringTimers = [];

    await mainWorker?.close();
    await criticalWorker?.close();
    await mainQueue?.close();
    await criticalQueue?.close();
    logger.info('Job queues shut down');
  },
};

export default jobQueue;
