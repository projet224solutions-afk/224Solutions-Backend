/**
 * 🛠️ PLACEMENT DE COMMANDE FOURNISSEUR (BACKEND) — Phase 3
 * ---------------------------------------------------------------------------
 * Charge une `dropship_orders` (créée automatiquement à l'achat, Phase 2), vérifie
 * la propriété (vendeur ou admin), appelle le connecteur fournisseur SERVEUR
 * (réel si credentials, sinon mock) et inscrit le résultat sur la commande.
 * Idempotent : une commande déjà placée n'est pas re-placée.
 */

import { supabaseAdmin } from '../../config/supabase.js';
import { logger } from '../../config/logger.js';
import { placeSupplierOrder, connectorMode, type ConnectorType } from './supplierConnectors.js';

const VALID_CONNECTORS: ConnectorType[] = ['ALIEXPRESS', 'ALIBABA', '1688', 'PRIVATE', 'CUSTOM'];

function normalizeConnector(raw?: string | null): ConnectorType {
  const up = (raw || '').toUpperCase().trim();
  return (VALID_CONNECTORS as string[]).includes(up) ? (up as ConnectorType) : 'CUSTOM';
}

export interface PlaceResult {
  success: boolean;
  alreadyPlaced?: boolean;
  mock?: boolean;
  supplierOrderId?: string;
  status?: string;
  error?: string;
  code?: string;
}

export async function placeDropshipOrder(
  dropshipOrderId: string,
  actor: { id: string; role?: string }
): Promise<PlaceResult> {
  // 1. Charger la commande fournisseur + le produit dropship source.
  const { data: order, error: oErr } = await supabaseAdmin
    .from('dropship_orders')
    .select('id, vendor_id, dropship_product_id, quantity, shipping_address, supplier_order_id, status')
    .eq('id', dropshipOrderId)
    .maybeSingle();
  if (oErr) throw oErr;
  if (!order) return { success: false, code: 'NOT_FOUND', error: 'Commande fournisseur introuvable' };

  // Idempotence : déjà placée.
  if (order.supplier_order_id) {
    return { success: true, alreadyPlaced: true, supplierOrderId: order.supplier_order_id, status: order.status };
  }

  // 2. Autorisation : vendeur propriétaire OU admin/PDG.
  const isAdmin = ['admin', 'pdg', 'ceo'].includes((actor.role || '').toLowerCase());
  if (!isAdmin) {
    const { data: vendor } = await supabaseAdmin
      .from('vendors').select('user_id').eq('id', order.vendor_id).maybeSingle();
    if (!vendor || vendor.user_id !== actor.id) {
      return { success: false, code: 'NOT_OWNER', error: 'Accès refusé' };
    }
  }

  // 3. Produit source (connecteur + id externe).
  const { data: dp } = await supabaseAdmin
    .from('dropship_products')
    .select('source_connector, source_product_id, source_url')
    .eq('id', order.dropship_product_id)
    .maybeSingle();
  if (!dp?.source_product_id) {
    return { success: false, code: 'NO_SOURCE', error: 'Produit source fournisseur manquant' };
  }

  const connector = normalizeConnector(dp.source_connector);

  // 4. Placement (réel si credentials, sinon mock).
  const result = await placeSupplierOrder(connector, {
    sourceProductId: dp.source_product_id,
    sourceUrl: dp.source_url || undefined,
    quantity: Number(order.quantity || 1),
    reference: order.id,
    shippingAddress: (order.shipping_address as Record<string, any>) || {},
  });

  // 5. Inscrire le résultat.
  if (result.success) {
    await supabaseAdmin.from('dropship_orders').update({
      supplier_order_id: result.supplierOrderId,
      supplier_order_reference: result.supplierOrderReference,
      placed_at: new Date().toISOString(),
      placement_is_mock: result.mock,
      placement_error: null,
      status: 'ordered_from_supplier',
    }).eq('id', order.id);
    logger.info(`[dropship-place] ${order.id} placée (${connector}, mock=${result.mock}) → ${result.supplierOrderId}`);
    return { success: true, mock: result.mock, supplierOrderId: result.supplierOrderId, status: 'ordered_from_supplier' };
  }

  await supabaseAdmin.from('dropship_orders').update({
    placement_error: result.error || 'Échec placement',
  }).eq('id', order.id);
  logger.warn(`[dropship-place] ${order.id} échec placement (${connector}): ${result.error}`);
  return { success: false, code: 'PLACEMENT_FAILED', error: result.error, mock: result.mock };
}

export { connectorMode };
