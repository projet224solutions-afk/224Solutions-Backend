/**
 * Applique la migration du LITIGE TRIPARTITE (relie dispute_messages à escrow_disputes)
 * via une connexion Postgres directe. Idempotente (IF NOT EXISTS / DROP POLICY IF EXISTS),
 * ré-exécutable sans danger, appliquée dans une transaction.
 *
 * Usage (récupère le mot de passe DB dans Supabase → Project Settings → Database) :
 *   DATABASE_URL="postgresql://postgres.uakkxaibujzxdiqzpnpr:<DB_PASSWORD>@aws-0-<region>.pooler.supabase.com:5432/postgres" \
 *   node backend/scripts/apply-dispute-migration.mjs
 *
 * (ou le host direct: db.uakkxaibujzxdiqzpnpr.supabase.co:5432)
 */
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

const __dirname = dirname(fileURLToPath(import.meta.url));
const MIGRATIONS_DIR = join(__dirname, '..', '..', 'supabase', 'migrations');
const FILE = process.argv[2] || '20260613100000_link_dispute_messages_to_escrow_disputes.sql';

const connectionString = process.env.DATABASE_URL;
if (!connectionString) {
  console.error('❌ DATABASE_URL manquant.');
  console.error('   Ex : postgresql://postgres.<ref>:<DB_PASSWORD>@<host>:5432/postgres');
  console.error('   (Supabase → Project Settings → Database → Connection string)');
  process.exit(1);
}

const client = new pg.Client({ connectionString, ssl: { rejectUnauthorized: false } });

const run = async () => {
  const sql = readFileSync(join(MIGRATIONS_DIR, FILE), 'utf8');
  await client.connect();
  console.log('✅ Connecté à Postgres');
  console.log(`▶️  Application de ${FILE} ...`);
  try {
    await client.query('BEGIN');
    await client.query(sql);
    await client.query('COMMIT');
    console.log('✅ Migration appliquée avec succès.');

    // Vérification : la colonne existe-t-elle bien ?
    const check = await client.query(
      `SELECT 1 FROM information_schema.columns
       WHERE table_name = 'dispute_messages' AND column_name = 'escrow_dispute_id'`,
    );
    console.log(check.rowCount > 0
      ? '✅ Vérif : colonne dispute_messages.escrow_dispute_id présente. Le fil tripartite est actif.'
      : '⚠️ Vérif : colonne non trouvée (à investiguer).');
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    console.error('❌ Échec, transaction annulée :', e.message);
    process.exitCode = 1;
  } finally {
    await client.end();
  }
};

run().catch((e) => { console.error(e); process.exit(1); });
