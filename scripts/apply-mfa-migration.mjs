/**
 * Applique la migration 2FA admin (20260614120000_admin_step_up_mfa.sql) via le
 * pooler Supavisor (port 6543, mode transaction). Idempotent (IF NOT EXISTS).
 *
 * Usage (depuis backend/) :
 *   SUPABASE_DB_PASSWORD='<mot de passe DB>' node scripts/apply-mfa-migration.mjs
 *
 * Le mot de passe DB se trouve dans Supabase → Settings → Database → Database password.
 * Rien n'est journalisé en clair.
 */
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

const PROJECT_REF = 'uakkxaibujzxdiqzpnpr';
const POOLER_HOST = 'aws-0-eu-west-2.pooler.supabase.com';

const password = process.env.SUPABASE_DB_PASSWORD;
if (!password) {
  console.error('❌ SUPABASE_DB_PASSWORD manquant. Voir Supabase → Settings → Database.');
  process.exit(1);
}

const __dirname = dirname(fileURLToPath(import.meta.url));
const sqlPath = join(__dirname, '..', '..', 'supabase', 'migrations', '20260614120000_admin_step_up_mfa.sql');
const sql = readFileSync(sqlPath, 'utf-8');

const connectionString = `postgresql://postgres.${PROJECT_REF}:${encodeURIComponent(password)}@${POOLER_HOST}:6543/postgres`;
const client = new pg.Client({ connectionString, ssl: { rejectUnauthorized: false } });

try {
  await client.connect();
  console.log('🔄 Application de la migration 2FA admin…');
  await client.query(sql);
  // Vérification : les 2 tables doivent exister
  const check = await client.query(`
    SELECT table_name FROM information_schema.tables
    WHERE table_schema='public' AND table_name IN ('admin_mfa','admin_mfa_events')
    ORDER BY table_name;`);
  console.log('✅ Migration appliquée. Tables présentes :', check.rows.map(r => r.table_name).join(', '));
  await client.end();
} catch (err) {
  try { await client.end(); } catch {}
  console.error('❌ Échec :', err.message?.split('\n')[0]);
  process.exit(1);
}
