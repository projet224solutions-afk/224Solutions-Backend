/**
 * 🔌 CONNECTEURS FOURNISSEURS (BACKEND) — placement de commande dropshipping
 * ---------------------------------------------------------------------------
 * Déplacé du frontend vers le backend (Phase 3) : les clés API fournisseur
 * vivent désormais en variables d'environnement SERVEUR — jamais au navigateur.
 *
 * Chaque connecteur tente l'appel RÉEL si ses credentials sont présents, sinon
 * retombe en MODE MOCK (commande fournisseur simulée, `mock: true`) — l'orchestration
 * (création de la commande fournisseur, suivi des statuts) fonctionne dès aujourd'hui ;
 * le jour où tu fournis les clés, le placement devient réel sans changer le reste.
 */

import { logger } from '../../config/logger.js';

export type ConnectorType = 'ALIEXPRESS' | 'ALIBABA' | '1688' | 'PRIVATE' | 'CUSTOM';

export interface PlaceOrderInput {
  sourceProductId: string;        // id produit chez le fournisseur
  sourceUrl?: string;
  quantity: number;
  reference: string;              // notre référence (dropship_order id)
  shippingAddress: Record<string, any>;
  notes?: string;
}

export interface PlaceOrderResult {
  success: boolean;
  mock: boolean;
  supplierOrderId?: string;
  supplierOrderReference?: string;
  totalCost?: number;
  currency?: string;
  error?: string;
}

interface ConnectorCreds {
  apiKey?: string;
  apiSecret?: string;
  accessToken?: string;
  baseUrl?: string;
}

// Résout les credentials d'un connecteur depuis l'environnement serveur.
function getCreds(type: ConnectorType): ConnectorCreds {
  const e = process.env;
  switch (type) {
    case 'ALIEXPRESS':
      return { apiKey: e.ALIEXPRESS_API_KEY, apiSecret: e.ALIEXPRESS_API_SECRET, accessToken: e.ALIEXPRESS_ACCESS_TOKEN, baseUrl: e.ALIEXPRESS_API_URL || 'https://api.aliexpress.com/v2' };
    case 'ALIBABA':
      return { apiKey: e.ALIBABA_API_KEY, apiSecret: e.ALIBABA_API_SECRET, baseUrl: e.ALIBABA_API_URL || 'https://api.alibaba.com/openapi' };
    case '1688':
      return { apiKey: e.ONE688_API_KEY, apiSecret: e.ONE688_API_SECRET, baseUrl: e.ONE688_API_URL || 'https://gw.open.1688.com/openapi' };
    case 'PRIVATE':
      return { apiKey: e.PRIVATE_SUPPLIER_API_KEY, baseUrl: e.PRIVATE_SUPPLIER_API_URL };
    default:
      return {};
  }
}

function hasRealCreds(c: ConnectorCreds): boolean {
  return Boolean((c.apiKey || c.accessToken) && c.baseUrl);
}

const PREFIX: Record<ConnectorType, string> = {
  ALIEXPRESS: 'AE', ALIBABA: 'ALB', '1688': '1688', PRIVATE: 'PRV', CUSTOM: 'CST',
};

function mockResult(type: ConnectorType, reference: string): PlaceOrderResult {
  const id = `${PREFIX[type] || 'SUP'}${Date.now()}`;
  logger.warn(`[dropship-connector] ${type} en MODE MOCK (pas de credentials) — commande simulée ${id}`);
  return {
    success: true, mock: true,
    supplierOrderId: id,
    supplierOrderReference: `REF-${reference.slice(0, 8)}-${id}`,
  };
}

/**
 * Place une commande chez le fournisseur. RÉEL si credentials présents, sinon MOCK.
 * NB : le contrat exact des API fournisseurs (signature, schéma de payload) dépend du
 * compte marchand ; le bloc « réel » ci-dessous POST le payload normalisé sur l'endpoint
 * configuré et lit { order_id, reference }. À ajuster au format réel le jour de l'activation.
 */
export async function placeSupplierOrder(type: ConnectorType, input: PlaceOrderInput): Promise<PlaceOrderResult> {
  const creds = getCreds(type);

  if (!hasRealCreds(creds)) {
    return mockResult(type, input.reference);
  }

  try {
    const resp = await fetch(`${creds.baseUrl}/orders`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(creds.accessToken ? { Authorization: `Bearer ${creds.accessToken}` } : {}),
        ...(creds.apiKey ? { 'X-Api-Key': creds.apiKey } : {}),
      },
      body: JSON.stringify({
        product_id: input.sourceProductId,
        quantity: input.quantity,
        reference: input.reference,
        shipping_address: input.shippingAddress,
        notes: input.notes,
      }),
    });

    if (!resp.ok) {
      const txt = await resp.text().catch(() => '');
      logger.error(`[dropship-connector] ${type} placement HTTP ${resp.status}: ${txt.slice(0, 200)}`);
      return { success: false, mock: false, error: `Fournisseur HTTP ${resp.status}` };
    }

    const data: any = await resp.json().catch(() => ({}));
    return {
      success: true, mock: false,
      supplierOrderId: String(data.order_id || data.supplierOrderId || data.id || ''),
      supplierOrderReference: String(data.reference || data.trade_no || ''),
      totalCost: typeof data.total === 'number' ? data.total : undefined,
      currency: data.currency,
    };
  } catch (e: any) {
    logger.error(`[dropship-connector] ${type} placement exception: ${e?.message}`);
    return { success: false, mock: false, error: e?.message || 'Erreur réseau fournisseur' };
  }
}

/** Indique si un connecteur est en mode réel (credentials présents) — pour l'UI/diagnostic. */
export function connectorMode(type: ConnectorType): 'real' | 'mock' {
  return hasRealCreds(getCreds(type)) ? 'real' : 'mock';
}

export interface SupplierTrackingSnapshot {
  trackingNumber?: string;
  carrier?: string;
  status?: string;
  trackingUrl?: string;
  delivered?: boolean;
}

/**
 * Rapatrie le suivi d'une commande fournisseur (Phase 5). RÉEL si credentials,
 * sinon `null` (mock = pas de faux tracking).
 */
export async function fetchSupplierTracking(type: ConnectorType, supplierOrderId: string): Promise<SupplierTrackingSnapshot | null> {
  const creds = getCreds(type);
  if (!hasRealCreds(creds)) return null;
  try {
    const resp = await fetch(`${creds.baseUrl}/orders/${encodeURIComponent(supplierOrderId)}/tracking`, {
      headers: {
        ...(creds.accessToken ? { Authorization: `Bearer ${creds.accessToken}` } : {}),
        ...(creds.apiKey ? { 'X-Api-Key': creds.apiKey } : {}),
      },
    });
    if (!resp.ok) {
      logger.warn(`[dropship-connector] ${type} fetch tracking HTTP ${resp.status} (${supplierOrderId})`);
      return null;
    }
    const d: any = await resp.json().catch(() => ({}));
    const status = String(d.status || '').toLowerCase();
    return {
      trackingNumber: d.tracking_number || d.trackingNumber || undefined,
      carrier: d.carrier || d.logistics_company || undefined,
      status: d.status || undefined,
      trackingUrl: d.tracking_url || d.trackingUrl || undefined,
      delivered: typeof d.delivered === 'boolean' ? d.delivered : (status.includes('deliver')),
    };
  } catch (e: any) {
    logger.warn(`[dropship-connector] ${type} fetch tracking exception (${supplierOrderId}): ${e?.message}`);
    return null;
  }
}

export interface SupplierProductSnapshot {
  price?: number;          // coût fournisseur actuel
  currency?: string;
  stockQuantity?: number;
  available?: boolean;
}

/**
 * Rafraîchit prix/stock d'un produit chez le fournisseur (pour la sync planifiée).
 * RÉEL si credentials présents. En MODE MOCK → retourne `null` : on NE fabrique PAS
 * de faux changements de prix/stock (évite de churner les données en dev).
 */
export async function fetchSupplierProduct(type: ConnectorType, sourceProductId: string): Promise<SupplierProductSnapshot | null> {
  const creds = getCreds(type);
  if (!hasRealCreds(creds)) return null;

  try {
    const resp = await fetch(`${creds.baseUrl}/products/${encodeURIComponent(sourceProductId)}`, {
      headers: {
        ...(creds.accessToken ? { Authorization: `Bearer ${creds.accessToken}` } : {}),
        ...(creds.apiKey ? { 'X-Api-Key': creds.apiKey } : {}),
      },
    });
    if (!resp.ok) {
      logger.warn(`[dropship-connector] ${type} fetch produit HTTP ${resp.status} (${sourceProductId})`);
      return null;
    }
    const d: any = await resp.json().catch(() => ({}));
    const stock = d.stock ?? d.stockQuantity ?? d.quantity;
    return {
      price: typeof d.price === 'number' ? d.price : (typeof d.cost === 'number' ? d.cost : undefined),
      currency: d.currency,
      stockQuantity: typeof stock === 'number' ? stock : undefined,
      available: typeof d.available === 'boolean' ? d.available : (typeof stock === 'number' ? stock > 0 : undefined),
    };
  } catch (e: any) {
    logger.warn(`[dropship-connector] ${type} fetch produit exception (${sourceProductId}): ${e?.message}`);
    return null;
  }
}
