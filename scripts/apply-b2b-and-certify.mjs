/**
 * 🚀 APPROVISIONNEMENT 224 — activation + certification en un geste.
 *
 * Applique les 3 migrations B2B (idempotentes) puis exécute le harnais de
 * certification (5 tests, ROLLBACK — zéro trace) et AFFICHE les preuves.
 *
 * Usage :
 *   DATABASE_URL="postgresql://postgres.<ref>:<PASSWORD>@aws-0-eu-west-2.pooler.supabase.com:5432/postgres" \
 *   node backend/scripts/apply-b2b-and-certify.mjs [--skip-certify] [--buyer email] [--supplier email]
 *
 * (mot de passe : Supabase Dashboard → Settings → Database. Jamais commité.)
 */
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

const __dirname = dirname(fileURLToPath(import.meta.url));
const MIGRATIONS_DIR = join(__dirname, '..', 'supabase', 'migrations');
const HARNESSES = [
  join(__dirname, '..', 'supabase', 'tests', 'b2b_certification_harness.sql'),
  join(__dirname, '..', 'supabase', 'tests', 'b2b_links_certification_harness.sql'),
];

const FILES = [
  // Approvisionnement 224 (côté acheteur)
  '20260717150000_b2b_supplier_link.sql',
  '20260717160000_b2b_purchase_orders.sql',
  '20260717170000_b2b_reception_pmp_payment.sql',
  // Espace Grossiste 224 (côté fournisseur : cockpit + liens de vente)
  '20260717200000_b2b_wholesale_foundation.sql',
  '20260717210000_b2b_stock_sale_links.sql',
];

const connectionString = process.env.DATABASE_URL;
if (!connectionString) {
  console.error('❌ DATABASE_URL manquant (Dashboard → Settings → Database).');
  process.exit(1);
}
const argv = process.argv.slice(2);
const flag = (name) => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : null;
};

const client = new pg.Client({ connectionString, ssl: { rejectUnauthorized: false } });
client.on('notice', (msg) => console.log(`  📢 ${msg.message}`));

const run = async () => {
  await client.connect();
  console.log('✅ Connecté à Postgres\n');

  for (const file of FILES) {
    const sql = readFileSync(join(MIGRATIONS_DIR, file), 'utf8');
    process.stdout.write(`→ ${file} ... `);
    try {
      await client.query('BEGIN');
      const res = await client.query(sql);
      await client.query('COMMIT');
      const last = Array.isArray(res) ? res[res.length - 1] : res;
      console.log(`OK ${last?.rows?.[0]?.status ? `— ${last.rows[0].status}` : ''}`);
    } catch (err) {
      await client.query('ROLLBACK');
      console.error(`❌ ÉCHEC : ${err.message}`);
      process.exit(1);
    }
  }

  if (!argv.includes('--skip-certify')) {
    const buyer = flag('--buyer');
    const supplier = flag('--supplier');
    for (const file of HARNESSES) {
      console.log(`\n═══ CERTIFICATION ${file.split(/[\\/]/).pop()} (ROLLBACK — zéro trace) ═══`);
      let harness = readFileSync(file, 'utf8');
      if (buyer) harness = harness.replaceAll('cert.a@224solutions.test', buyer);
      if (supplier) harness = harness.replaceAll('cert.b@224solutions.test', supplier);
      try {
        await client.query(harness); // BEGIN…ROLLBACK inclus dans le fichier
        console.log('✅ Toutes les assertions ont tenu (preuves ci-dessus).');
      } catch (err) {
        console.error(`❌ CERTIFICATION ÉCHOUÉE : ${err.message}`);
        try { await client.query('ROLLBACK'); } catch { /* déjà rollbacké */ }
        process.exit(1);
      }
    }
  }

  await client.end();
};

run().catch((e) => { console.error(e); process.exit(1); });
