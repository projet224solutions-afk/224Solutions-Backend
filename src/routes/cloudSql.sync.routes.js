/**
 * 🔄 CLOUD SQL SYNC ROUTES
 * Routes Express pour recevoir les données de Supabase
 * et les insérer dans Google Cloud SQL
 */

import express from 'express';
import { query, withTransaction } from '../config/cloudSql.js';
import { logger } from '../config/logger.js';

const router = express.Router();

/**
 * Middleware: Vérifier la clé API de sync
 */
function verifySyncApiKey(req, res, next) {
  const apiKey = req.headers['x-sync-api-key'];
  const expectedKey = process.env.CLOUD_SQL_SYNC_API_KEY;

  if (!expectedKey || apiKey !== expectedKey) {
    return res.status(401).json({ error: 'Clé API de synchronisation invalide' });
  }
  next();
}

router.use(verifySyncApiKey);

/**
 * POST /api/cloudsql/sync-user
 * Synchronise un utilisateur Supabase → Cloud SQL
 */
router.post('/sync-user', async (req, res) => {
  try {
    const {
      supabase_user_id, email, full_name, first_name, last_name,
      phone, avatar_url, city, country, role, created_at
    } = req.body;

    const result = await query(
      `INSERT INTO users (supabase_user_id, email, full_name, first_name, last_name, phone, avatar_url, city, country, role, created_at, last_login_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, NOW())
       ON CONFLICT (supabase_user_id)
       DO UPDATE SET
         email = EXCLUDED.email,
         full_name = COALESCE(EXCLUDED.full_name, users.full_name),
         first_name = COALESCE(EXCLUDED.first_name, users.first_name),
         last_name = COALESCE(EXCLUDED.last_name, users.last_name),
         phone = COALESCE(EXCLUDED.phone, users.phone),
         avatar_url = COALESCE(EXCLUDED.avatar_url, users.avatar_url),
         city = COALESCE(EXCLUDED.city, users.city),
         country = COALESCE(EXCLUDED.country, users.country),
         last_login_at = NOW(),
         updated_at = NOW()
       RETURNING id`,
      [supabase_user_id, email, full_name, first_name, last_name, phone, avatar_url, city, country, role, created_at]
    );

    logger.info(`✅ User synced to Cloud SQL: ${supabase_user_id}`);
    res.json({ success: true, cloudSqlUserId: result.rows[0]?.id });
  } catch (error) {
    logger.error(`❌ Sync user error: ${error.message}`);
    res.status(500).json({ error: error.message });
  }
});

/**
 * POST /api/cloudsql/sync-order
 * Synchronise une commande Supabase → Cloud SQL
 */
router.post('/sync-order', async (req, res) => {
  try {
    const order = req.body;

    const result = await withTransaction(async (client) => {
      // Upsert la commande
      const orderResult = await client.query(
        `INSERT INTO orders (supabase_order_id, customer_id, vendor_id, order_number, status,
         payment_status, payment_method, subtotal, tax_amount, shipping_amount,
         discount_amount, total_amount, shipping_address, notes, created_at)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
         ON CONFLICT (supabase_order_id)
         DO UPDATE SET
           status = EXCLUDED.status,
           payment_status = EXCLUDED.payment_status,
           total_amount = EXCLUDED.total_amount,
           updated_at = NOW()
         RETURNING id`,
        [
          order.id, order.customer_id, order.vendor_id, order.order_number,
          order.status, order.payment_status, order.payment_method,
          order.subtotal, order.tax_amount, order.shipping_amount,
          order.discount_amount, order.total_amount,
          JSON.stringify(order.shipping_address), order.notes, order.created_at
        ]
      );

      // Sync les items de commande
      if (order.order_items?.length > 0) {
        for (const item of order.order_items) {
          await client.query(
            `INSERT INTO order_items (supabase_item_id, order_id, product_id, quantity, unit_price, total_price)
             VALUES ($1, $2, $3, $4, $5, $6)
             ON CONFLICT (supabase_item_id) DO UPDATE SET
               quantity = EXCLUDED.quantity,
               total_price = EXCLUDED.total_price`,
            [item.id, orderResult.rows[0].id, item.product_id, item.quantity, item.unit_price, item.total_price]
          );
        }
      }

      return orderResult.rows[0];
    });

    logger.info(`✅ Order synced to Cloud SQL: ${order.id}`);
    res.json({ success: true, cloudSqlOrderId: result?.id });
  } catch (error) {
    logger.error(`❌ Sync order error: ${error.message}`);
    res.status(500).json({ error: error.message });
  }
});

/**
 * POST /api/cloudsql/sync-transaction
 * Synchronise une transaction wallet → Cloud SQL
 */
router.post('/sync-transaction', async (req, res) => {
  try {
    const tx = req.body;

    await query(
      `INSERT INTO wallet_transactions_cloud (supabase_tx_id, user_id, amount, type, status, currency, description, created_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
       ON CONFLICT (supabase_tx_id) DO UPDATE SET
         status = EXCLUDED.status,
         updated_at = NOW()`,
      [tx.id, tx.user_id, tx.amount, tx.type, tx.status, tx.currency, tx.description, tx.created_at]
    );

    logger.info(`✅ Transaction synced to Cloud SQL: ${tx.id}`);
    res.json({ success: true });
  } catch (error) {
    logger.error(`❌ Sync transaction error: ${error.message}`);
    res.status(500).json({ error: error.message });
  }
});

/**
 * POST /api/cloudsql/bulk-sync
 * Synchronisation en masse d'une table
 */
router.post('/bulk-sync', async (req, res) => {
  try {
    const { table, rows } = req.body;

    if (!table || !rows || !Array.isArray(rows)) {
      return res.status(400).json({ error: 'Table et rows requis' });
    }

    // Tables autorisées pour la sync
    const allowedTables = [
      'profiles', 'vendors', 'orders', 'order_items', 'products',
      'wallets', 'wallet_transactions', 'deliveries', 'escrows',
      'agents_management', 'pdg_management', 'categories',
      'digital_products', 'digital_subscriptions'
    ];

    if (!allowedTables.includes(table)) {
      return res.status(403).json({ error: `Table ${table} non autorisée pour la sync` });
    }

    let synced = 0;
    let failed = 0;

    await withTransaction(async (client) => {
      for (const row of rows) {
        try {
          const columns = Object.keys(row);
          const values = Object.values(row);
          const placeholders = columns.map((_, i) => `$${i + 1}`).join(', ');
          const columnNames = columns.join(', ');

          await client.query(
            `INSERT INTO ${table}_cloud (${columnNames}, supabase_id)
             VALUES (${placeholders}, $${columns.length + 1})
             ON CONFLICT (supabase_id) DO UPDATE SET
             ${columns.map(c => `${c} = EXCLUDED.${c}`).join(', ')},
             synced_at = NOW()`,
            [...values, row.id]
          );
          synced++;
        } catch (err) {
          failed++;
          logger.warn(`⚠️ Bulk sync row error (${table}): ${err.message}`);
        }
      }
    });

    logger.info(`✅ Bulk sync ${table}: ${synced} ok, ${failed} failed`);
    res.json({ success: true, synced, failed, total: rows.length });
  } catch (error) {
    logger.error(`❌ Bulk sync error: ${error.message}`);
    res.status(500).json({ error: error.message });
  }
});

export default router;
