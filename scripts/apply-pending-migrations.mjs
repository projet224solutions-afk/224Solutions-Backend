/**
 * Applique les migrations en attente (session stock/POS/abonnements/entrepôts)
 * via une connexion Postgres directe.
 *
 * Usage :
 *   DATABASE_URL="postgresql://postgres.<ref>:<password>@<host>:5432/postgres" \
 *   node backend/scripts/apply-pending-migrations.mjs
 *
 * Toutes ces migrations sont idempotentes (CREATE OR REPLACE / IF NOT EXISTS),
 * donc ré-exécutables sans danger. Chaque fichier est appliqué dans une
 * transaction ; en cas d'erreur, on s'arrête (l'ordre compte).
 */
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

const __dirname = dirname(fileURLToPath(import.meta.url));
const MIGRATIONS_DIR = join(__dirname, '..', '..', 'supabase', 'migrations');

// Ordre = dépendances respectées (noms chronologiques)
const FILES = [
  '20260603100000_drop_vendor_api_system.sql',
  '20260603110000_fix_subscription_missing_columns.sql',
  '20260603120000_harden_identity_columns.sql',
  '20260603120000_robust_phone_resolution.sql',
  '20260603130000_one_active_paid_subscription.sql',
  '20260604000000_fix_stock_double_decrement_and_inventory.sql',
  '20260604010000_pos_sale_tax_server_side.sql',
  '20260604020000_create_pos_order_complete.sql',
  '20260604030000_subscriptions_true_atomic.sql',
  '20260604040000_harden_atomic_functions_grants.sql',
  '20260604120000_notifications_add_metadata.sql',
  '20260605000000_atomic_stock_adjustment.sql',
  '20260605010000_fix_ship_transfer_toctou.sql',
  '20260605020000_atomic_location_stock_adjust.sql',
  '20260605030000_option_b_warehouse_to_shop_sync.sql',
  '20260605040000_unify_location_stock_quantity_model.sql',
];

const connectionString = process.env.DATABASE_URL;
if (!connectionString) {
  console.error('❌ DATABASE_URL manquant. Ex : postgresql://postgres.<ref>:<pwd>@<host>:5432/postgres');
  process.exit(1);
}

const client = new pg.Client({
  connectionString,
  ssl: { rejectUnauthorized: false }, // Supabase exige TLS
});

const run = async () => {
  await client.connect();
  console.log('✅ Connecté à Postgres\n');
  for (const file of FILES) {
    const sql = readFileSync(join(MIGRATIONS_DIR, file), 'utf8');
    process.stdout.write(`→ ${file} ... `);
    try {
      await client.query('BEGIN');
      await client.query(sql);
      await client.query('COMMIT');
      console.log('OK');
    } catch (err) {
      await client.query('ROLLBACK');
      console.log('ÉCHEC');
      console.error(`   ${err.message}`);
      await client.end();
      process.exit(1);
    }
  }
  await client.end();
  console.log('\n🎉 Toutes les migrations appliquées.');
};

run().catch(async (e) => {
  console.error(e.message);
  try { await client.end(); } catch {}
  process.exit(1);
});
