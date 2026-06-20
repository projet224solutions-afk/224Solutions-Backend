/**
 * 📦 TRACKING RAPATRIÉ DROPSHIPPING (BACKEND) — Phase 5
 * ---------------------------------------------------------------------------
 * Récupère le n° de suivi de la commande fournisseur (connecteur serveur) et :
 *   - met à jour `dropship_orders` (tracking_number + statut) ;
 *   - écrit le suivi dans la commande CLIENT (`orders.metadata`) ;
 *   - NOTIFIE l'acheteur (expédition / livraison).
 *
 * MODE MOCK (pas de credentials) → `fetchSupplierTracking` renvoie null → no-op.
 */

import { supabaseAdmin } from '../../config/supabase.js';
import { logger } from '../../config/logger.js';
import { createNotification } from '../notification.service.js';
import { fetchSupplierTracking, type ConnectorType } from './supplierConnectors.js';

const VALID: ConnectorType[] = ['ALIEXPRESS', 'ALIBABA', '1688', 'PRIVATE', 'CUSTOM'];
const normalize = (raw?: string | null): ConnectorType => {
  const up = (raw || '').toUpperCase().trim();
  return (VALID as string[]).includes(up) ? (up as ConnectorType) : 'CUSTOM';
};

const TERMINAL = ['delivered_to_customer', 'completed', 'cancelled', 'refunded'];

interface DropshipOrderRow {
  id: string;
  supplier_order_id: string | null;
  dropship_product_id: string | null;
  customer_order_id: string | null;
  tracking_number: string | null;
  status: string | null;
}

/** Notifie l'acheteur (résout customers.user_id depuis orders.customer_id). */
async function notifyBuyer(customerOrderId: string, title: string, message: string, trackingNumber: string): Promise<void> {
  try {
    const { data: order } = await supabaseAdmin.from('orders').select('customer_id').eq('id', customerOrderId).maybeSingle();
    if (!order?.customer_id) return;
    const { data: cust } = await supabaseAdmin.from('customers').select('user_id').eq('id', order.customer_id).maybeSingle();
    if (!cust?.user_id) return;
    await createNotification({
      userId: cust.user_id, type: 'order', title, message,
      metadata: { order_id: customerOrderId, tracking_number: trackingNumber },
    });
  } catch (e: any) {
    logger.warn(`[dropship-tracking] notif acheteur échouée (${customerOrderId}): ${e?.message}`);
  }
}

/** Écrit le suivi dans la commande client (fusion non destructive de metadata). */
async function writeTrackingToOrder(customerOrderId: string, tn: string, carrier?: string, url?: string, status?: string): Promise<void> {
  const { data: order } = await supabaseAdmin.from('orders').select('metadata').eq('id', customerOrderId).maybeSingle();
  const metadata = { ...((order?.metadata as Record<string, any>) || {}), tracking_number: tn, tracking_carrier: carrier || null, tracking_url: url || null, tracking_status: status || null };
  await supabaseAdmin.from('orders').update({ metadata }).eq('id', customerOrderId);
}

export async function syncTrackingForOrder(row: DropshipOrderRow): Promise<{ changed: boolean; status?: string }> {
  if (!row.supplier_order_id) return { changed: false };

  const { data: dp } = await supabaseAdmin
    .from('dropship_products').select('source_connector').eq('id', row.dropship_product_id).maybeSingle();

  const snap = await fetchSupplierTracking(normalize(dp?.source_connector), row.supplier_order_id);
  if (!snap?.trackingNumber) return { changed: false };

  const newStatus = snap.delivered ? 'delivered_to_customer' : 'shipped_by_supplier';
  const trackingChanged = snap.trackingNumber !== row.tracking_number;
  const statusChanged = newStatus !== row.status;
  if (!trackingChanged && !statusChanged) return { changed: false };

  await supabaseAdmin.from('dropship_orders')
    .update({ tracking_number: snap.trackingNumber, status: newStatus })
    .eq('id', row.id);

  if (row.customer_order_id) {
    await writeTrackingToOrder(row.customer_order_id, snap.trackingNumber, snap.carrier, snap.trackingUrl, snap.status);

    // Notifier : 1ère apparition du suivi (expédié) OU livraison.
    if (!row.tracking_number && snap.trackingNumber) {
      await notifyBuyer(row.customer_order_id, 'Votre commande est expédiée 📦',
        `Suivi : ${snap.trackingNumber}${snap.carrier ? ' (' + snap.carrier + ')' : ''}.`, snap.trackingNumber);
    } else if (snap.delivered && row.status !== 'delivered_to_customer') {
      await notifyBuyer(row.customer_order_id, 'Votre commande est livrée ✅',
        `Votre colis (${snap.trackingNumber}) a été livré.`, snap.trackingNumber);
    }
  }

  logger.info(`[dropship-tracking] ${row.id} → ${newStatus} (${snap.trackingNumber})`);
  return { changed: true, status: newStatus };
}

/** Rapatrie le suivi pour toutes les commandes fournisseur placées et non terminées. */
export async function syncAllTracking(): Promise<{ checked: number; updated: number }> {
  const { data: rows, error } = await supabaseAdmin
    .from('dropship_orders')
    .select('id, supplier_order_id, dropship_product_id, customer_order_id, tracking_number, status')
    .not('supplier_order_id', 'is', null)
    .not('status', 'in', `(${TERMINAL.join(',')})`)
    .limit(500);
  if (error) {
    logger.error(`[dropship-tracking] lecture échouée: ${error.message}`);
    return { checked: 0, updated: 0 };
  }

  let updated = 0;
  for (const row of (rows || []) as DropshipOrderRow[]) {
    try {
      if ((await syncTrackingForOrder(row)).changed) updated++;
    } catch (e: any) {
      logger.warn(`[dropship-tracking] ${row.id} échec: ${e?.message}`);
    }
  }
  const summary = { checked: (rows || []).length, updated };
  logger.info(`[dropship-tracking] terminé: ${JSON.stringify(summary)}`);
  return summary;
}
