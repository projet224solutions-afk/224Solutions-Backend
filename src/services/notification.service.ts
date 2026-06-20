/**
 * 🔔 NOTIFICATION SERVICE - Backend Node.js
 *
 * Source de vérité unique : table `notifications` (lue par le frontend :
 * NotificationBellButton, useUserNotifications, useVendorNotifications,
 * useNotificationsRealtime). Toute notification in-app doit passer par ici.
 *
 * Résilience : si la colonne `metadata` n'existe pas encore en base
 * (migration 20260604120000 non appliquée), on réessaie sans metadata
 * pour que la notification arrive quand même. Une notification ne doit
 * JAMAIS faire échouer le flux métier appelant (commande, paiement…).
 */

import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

export interface CreateNotificationInput {
  /** auth.users.id du destinataire (PAS customers.id / vendors.id) */
  userId: string;
  title: string;
  message: string;
  /** ex: 'order', 'payment', 'order_confirmed', 'system', 'security' */
  type: string;
  metadata?: Record<string, unknown>;
}

/** Détecte l'erreur « colonne metadata absente » (schema cache PostgREST). */
function isMissingMetadataColumn(error: { message?: string } | null): boolean {
  const msg = error?.message?.toLowerCase() || '';
  return msg.includes('metadata') && (msg.includes('column') || msg.includes('schema cache'));
}

/**
 * Insère une notification in-app. Ne lève jamais : renvoie true si livrée.
 */
export async function createNotification(input: CreateNotificationInput): Promise<boolean> {
  const { userId, title, message, type, metadata } = input;
  if (!userId) {
    logger.warn('[notification] userId manquant, notification ignorée');
    return false;
  }

  const base = { user_id: userId, title, message, type, read: false };

  try {
    // 1) Tentative avec metadata (cas nominal une fois la colonne en place)
    const { error } = await supabaseAdmin
      .from('notifications')
      .insert(metadata ? { ...base, metadata } : base);

    if (!error) return true;

    // 2) Repli sans metadata si la colonne n'existe pas encore
    if (metadata && isMissingMetadataColumn(error)) {
      const { error: retryError } = await supabaseAdmin.from('notifications').insert(base);
      if (!retryError) {
        logger.warn('[notification] colonne metadata absente — notification livrée sans metadata (appliquer la migration 20260604120000)');
        return true;
      }
      logger.error(`[notification] échec (sans metadata): ${retryError.message}`);
      return false;
    }

    logger.error(`[notification] échec insertion: ${error.message}`);
    return false;
  } catch (err: any) {
    logger.error(`[notification] exception: ${err?.message || err}`);
    return false;
  }
}

/** Insère la même notification pour plusieurs destinataires (best-effort). */
export async function createNotifications(inputs: CreateNotificationInput[]): Promise<number> {
  let delivered = 0;
  for (const input of inputs) {
    if (await createNotification(input)) delivered += 1;
  }
  return delivered;
}
