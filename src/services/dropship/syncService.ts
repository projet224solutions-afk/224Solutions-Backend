/**
 * 🔄 SYNC PRIX / STOCK DROPSHIPPING (BACKEND) — Phase 4
 * ---------------------------------------------------------------------------
 * Rafraîchit prix de gros + stock depuis le fournisseur (connecteur serveur) et :
 *   - met à jour `dropship_products` (coût/stock/dispo) et le produit catalogue miroir ;
 *   - DÉPUBLIE automatiquement les produits en RUPTURE (anti-survente) ;
 *   - ALERTE (system_alerts) si le coût fournisseur dépasse le prix de vente (perte).
 *
 * MODE MOCK (pas de credentials fournisseur) → `fetchSupplierProduct` renvoie null :
 * la sync est un no-op (aucune fausse donnée). Réel dès que les clés sont posées.
 */

import { supabaseAdmin } from '../../config/supabase.js';
import { logger } from '../../config/logger.js';
import { fetchSupplierProduct, type ConnectorType } from './supplierConnectors.js';

const VALID: ConnectorType[] = ['ALIEXPRESS', 'ALIBABA', '1688', 'PRIVATE', 'CUSTOM'];
const normalize = (raw?: string | null): ConnectorType => {
  const up = (raw || '').toUpperCase().trim();
  return (VALID as string[]).includes(up) ? (up as ConnectorType) : 'CUSTOM';
};

export interface SyncSummary {
  checked: number;
  updated: number;
  outOfStock: number;
  lossFlagged: number;
  skipped: number;
}

/** Insère une alerte system_alerts si aucune alerte active de même clé n'existe (dedup). */
async function upsertAlert(alertKey: string, title: string, message: string, severity: string, suggestedFix?: string): Promise<void> {
  try {
    const { data: existing } = await supabaseAdmin
      .from('system_alerts')
      .select('id')
      .eq('module', 'dropshipping')
      .eq('status', 'active')
      .filter('metadata->>alert_key', 'eq', alertKey)
      .maybeSingle();
    if (existing) return;
    await supabaseAdmin.from('system_alerts').insert({
      title, message, severity, module: 'dropshipping', status: 'active',
      suggested_fix: suggestedFix || null, metadata: { alert_key: alertKey },
    });
  } catch (e: any) {
    logger.warn(`[dropship-sync] alerte non insérée (${alertKey}): ${e?.message}`);
  }
}

export async function syncAllDropshipProducts(): Promise<SyncSummary> {
  const summary: SyncSummary = { checked: 0, updated: 0, outOfStock: 0, lossFlagged: 0, skipped: 0 };

  const { data: rows, error } = await supabaseAdmin
    .from('dropship_products')
    .select('id, source_connector, source_product_id, supplier_price, cost_price, selling_price, stock_quantity, is_available, is_published, published_product_id, auto_sync')
    .not('source_product_id', 'is', null)
    .limit(1000);
  if (error) {
    logger.error(`[dropship-sync] lecture produits échouée: ${error.message}`);
    return summary;
  }

  for (const dp of rows || []) {
    if ((dp as any).auto_sync === false) { summary.skipped++; continue; }
    summary.checked++;

    const snap = await fetchSupplierProduct(normalize(dp.source_connector), dp.source_product_id);
    if (!snap) { summary.skipped++; continue; } // mock / pas de credentials / erreur → pas de changement

    const newCost = typeof snap.price === 'number' ? snap.price : dp.cost_price;
    const newStock = typeof snap.stockQuantity === 'number' ? snap.stockQuantity : dp.stock_quantity;
    const available = typeof snap.available === 'boolean' ? snap.available : (newStock ?? 0) > 0;

    // 1. MAJ dropship_products (coût/stock/dispo).
    await supabaseAdmin.from('dropship_products').update({
      cost_price: newCost,
      supplier_price: newCost,
      stock_quantity: newStock,
      is_available: available,
      last_sync_at: new Date().toISOString(),
      sync_status: 'synced',
    }).eq('id', dp.id);

    // 2. MAJ du produit catalogue miroir (stock + coût).
    if (dp.published_product_id) {
      await supabaseAdmin.from('products').update({
        stock_quantity: newStock ?? 0,
        cost_price: newCost,
        updated_at: new Date().toISOString(),
      }).eq('id', dp.published_product_id);
    }
    summary.updated++;

    // 3. RUPTURE → dépublier (anti-survente) + alerte.
    if (!available || (newStock ?? 0) <= 0) {
      summary.outOfStock++;
      if (dp.published_product_id && dp.is_published) {
        await supabaseAdmin.from('products').update({ is_active: false, updated_at: new Date().toISOString() }).eq('id', dp.published_product_id);
        await supabaseAdmin.from('dropship_products').update({ is_published: false }).eq('id', dp.id);
      }
      await upsertAlert(
        `dropship_oos:${dp.id}`,
        `[dropshipping] Rupture fournisseur — produit dépublié`,
        `Le produit dropship ${dp.id} est en rupture chez le fournisseur → retiré du marketplace (anti-survente).`,
        'medium',
        'Re-synchroniser ou re-publier manuellement une fois le stock fournisseur rétabli.'
      );
    }

    // 4. PERTE (coût fournisseur > prix de vente) → alerte (sans changer le prix de vente).
    if (typeof newCost === 'number' && typeof dp.selling_price === 'number' && newCost > dp.selling_price) {
      summary.lossFlagged++;
      await upsertAlert(
        `dropship_loss:${dp.id}`,
        `[dropshipping] Marge négative — coût fournisseur > prix de vente`,
        `Produit dropship ${dp.id} : coût fournisseur ${newCost} > prix de vente ${dp.selling_price}. Vente à perte.`,
        'high',
        'Augmenter le prix de vente ou dépublier le produit.'
      );
    }
  }

  logger.info(`[dropship-sync] terminé: ${JSON.stringify(summary)}`);
  return summary;
}
