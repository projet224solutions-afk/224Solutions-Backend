/**
 * Applique la migration de géocodage rétroactif des services de proximité :
 *   vista-flows/supabase/migrations/20260627000001_city_coordinates_reference.sql
 *
 * Migration idempotente (CREATE IF NOT EXISTS / CREATE OR REPLACE / ON CONFLICT)
 * → ré-exécutable sans danger. Le fichier gère sa propre transaction (BEGIN/COMMIT).
 *
 * Connexion : DATABASE_URL (chaîne Postgres Supabase avec mot de passe).
 *   À récupérer dans Supabase Dashboard → Settings → Database → Connection string
 *   (URI, mode "Session" ou "Transaction"). Exemple :
 *     postgresql://postgres.<ref>:<password>@aws-0-<region>.pooler.supabase.com:6543/postgres
 *
 * Usage (le secret reste dans TON shell ou backend/.env, jamais dans le chat) :
 *   A) inline :
 *      DATABASE_URL="postgresql://..." node scripts/apply-geocoding-migration.mjs
 *   B) via backend/.env : ajoute une ligne DATABASE_URL=... puis
 *      node scripts/apply-geocoding-migration.mjs
 */
import { readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

const __dirname = dirname(fileURLToPath(import.meta.url));

// Migration ciblée (dépôt vista-flows, voisin du backend sous 224Solutions/)
const MIGRATION_FILE = join(
  __dirname, '..', '..', 'vista-flows', 'supabase', 'migrations',
  '20260627000001_city_coordinates_reference.sql',
);

// Récupère DATABASE_URL depuis l'env, sinon depuis backend/.env (parse minimal,
// sans dépendance) — évite de coller le secret dans le chat.
function resolveDatabaseUrl() {
  if (process.env.DATABASE_URL) return process.env.DATABASE_URL;
  const envPath = join(__dirname, '..', '.env');
  if (existsSync(envPath)) {
    for (const raw of readFileSync(envPath, 'utf8').split(/\r?\n/)) {
      const line = raw.trim();
      if (!line || line.startsWith('#')) continue;
      const eq = line.indexOf('=');
      if (eq === -1) continue;
      if (line.slice(0, eq).trim() === 'DATABASE_URL') {
        return line.slice(eq + 1).trim().replace(/^["']|["']$/g, '');
      }
    }
  }
  return null;
}

const connectionString = resolveDatabaseUrl();
if (!connectionString) {
  console.error('❌ DATABASE_URL introuvable (ni en env, ni dans backend/.env).');
  console.error('   Récupère-la dans Supabase Dashboard → Settings → Database → Connection string.');
  process.exit(1);
}
if (!existsSync(MIGRATION_FILE)) {
  console.error(`❌ Migration introuvable : ${MIGRATION_FILE}`);
  process.exit(1);
}

const client = new pg.Client({
  connectionString,
  ssl: { rejectUnauthorized: false }, // Supabase exige TLS
});

const run = async () => {
  const sql = readFileSync(MIGRATION_FILE, 'utf8');
  await client.connect();
  console.log('✅ Connecté à Postgres');
  console.log('→ 20260627000001_city_coordinates_reference.sql ...');
  try {
    // Le fichier contient déjà BEGIN/COMMIT : on l'exécute tel quel.
    await client.query(sql);
    console.log('🎉 Migration appliquée.');
  } catch (err) {
    console.error('❌ ÉCHEC :', err.message);
    await client.end();
    process.exit(1);
  }

  // Vérification post-migration
  const checks = await client.query(`
    SELECT
      (SELECT count(*) FROM public.city_coordinates) AS villes,
      (SELECT count(*) FROM pg_proc WHERE proname IN
        ('backfill_services_geolocation','list_ungeocoded_cities','normalize_city_key')) AS rpc
  `);
  const { villes, rpc } = checks.rows[0];
  console.log(`   villes référencées : ${villes} · fonctions créées : ${rpc}/3`);
  console.log('   → Lance ensuite le backfill (bouton PDG « Géocoder les services »');
  console.log('     ou SELECT public.backfill_services_geolocation(); en tant qu\'admin).');

  await client.end();
};

run().catch(async (e) => {
  console.error(e.message);
  try { await client.end(); } catch { /* noop */ }
  process.exit(1);
});
