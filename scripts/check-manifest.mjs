#!/usr/bin/env node
/**
 * 🔒 LA CONNAISSANCE NE PEUT PAS POURRIR (§8.4.2 / §8.6.1).
 * Contrôle CI du manifeste contre le CODE RÉEL, à chaque push :
 *   A. toute RPC citée existe dans les migrations (CREATE FUNCTION) ;
 *   B. tout fichier source cité existe ;
 *   C. toute route citée existe dans les routes Express ;
 *   D. toute route MAJEURE servie est mémorisée — sinon le contrôle ÉCHOUE en
 *      GÉNÉRANT le brouillon d'entrée manifeste (il ne reste qu'à compléter les invariants).
 * Sortie non nulle = build rouge : il est structurellement impossible de livrer une
 * fonctionnalité majeure non mémorisée.
 */
import { readdirSync, readFileSync, existsSync, statSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const MANIFEST_DIR = join(ROOT, 'feature-manifest');
const ROUTES_DIR = join(ROOT, 'src', 'routes');
const MIGRATIONS_DIR = join(ROOT, 'supabase', 'migrations');

// Routes considérées MAJEURES : leur fichier expose un flux métier de premier plan.
// Étendre cette liste = exiger la mémorisation d'un nouveau domaine.
const MAJOR_ROUTE_FILES = [
  'orders.routes.ts', 'pos.routes.ts', 'wallet.v2.routes.ts', 'delivery.routes.ts',
  'taxi.routes.ts', 'quotes.routes.ts', 'bookings.routes.ts', 'inventory.routes.ts',
  'paymentLinks.routes.ts', 'digital.routes.ts',
];

const read = (p) => readFileSync(p, 'utf8');
const fail = [];
const warn = [];

// ── Manifeste ───────────────────────────────────────────────────────────────
if (!existsSync(MANIFEST_DIR)) {
  console.error('❌ feature-manifest/ absent');
  process.exit(1);
}
const features = [];
const probes = [];
for (const f of readdirSync(MANIFEST_DIR).filter((n) => n.endsWith('.json'))) {
  const raw = JSON.parse(read(join(MANIFEST_DIR, f)));
  features.push(...(raw.features || []));
  probes.push(...(raw.probes || []));
}
if (features.length === 0) { console.error('❌ manifeste vide'); process.exit(1); }

// ── Corpus du code réel ─────────────────────────────────────────────────────
const migrationSql = readdirSync(MIGRATIONS_DIR)
  .filter((n) => n.endsWith('.sql'))
  .map((n) => read(join(MIGRATIONS_DIR, n)))
  .join('\n');
const routeFiles = readdirSync(ROUTES_DIR).filter((n) => n.endsWith('.ts') || n.endsWith('.js'));
const routesSrc = routeFiles.map((n) => read(join(ROUTES_DIR, n))).join('\n');

// A. RPC citées → existent en migration ?
for (const f of features) {
  for (const rpc of f.rpcs || []) {
    const re = new RegExp(`CREATE\\s+(OR\\s+REPLACE\\s+)?FUNCTION\\s+(public\\.)?${rpc}\\s*\\(`, 'i');
    if (!re.test(migrationSql)) {
      fail.push(`RPC introuvable dans les migrations : « ${rpc} » (fonctionnalité ${f.feature_key})`);
    }
  }
  // B. sources citées → fichiers existants (chemin avant ':')
  for (const s of f.sources || []) {
    const p = String(s).split(':')[0].split(' ')[0];
    if (p.includes('/') && !existsSync(join(ROOT, p)) && !existsSync(join(ROOT, '..', 'vista-flows', p))) {
      warn.push(`source citée introuvable : ${p} (${f.feature_key})`);
    }
  }
  // C. routes citées → chemin présent dans un fichier de routes
  for (const r of f.routes || []) {
    const [, path] = String(r).split(/\s+/);
    if (!path) continue;
    const leaf = path.replace(/^\/api(\/v2)?/, '').replace(/:[^/]+/g, '').replace(/\/+$/, '');
    const needle = leaf.split('/').filter(Boolean).pop();
    if (needle && !routesSrc.includes(needle)) {
      warn.push(`route citée sans trace dans src/routes : ${r} (${f.feature_key})`);
    }
  }
}

// D. routes MAJEURES servies mais NON mémorisées → brouillon généré
const known = new Set();
for (const f of features) for (const r of f.routes || []) known.add(String(r).split(/\s+/)[1]);
const draft = [];
for (const file of MAJOR_ROUTE_FILES) {
  const p = join(ROUTES_DIR, file);
  if (!existsSync(p)) continue;
  const src = read(p);
  const declared = [...src.matchAll(/router\.(get|post|put|patch|delete)\(\s*['"`]([^'"`]+)['"`]/g)]
    .map((m) => ({ method: m[1].toUpperCase(), path: m[2] }));
  // On n'exige QUE les racines métier (pas chaque sous-route) : une feature couvre un préfixe.
  const covered = [...known].some((k) => k && declared.some((d) => k.includes(d.path) || d.path.includes(k.split('/').pop() || '@@')));
  if (declared.length > 0 && !covered) {
    draft.push({
      feature_key: `TODO.${file.replace(/\.routes\.(ts|js)$/, '')}`,
      interface: 'TODO',
      label: `TODO — ${file}`,
      criticality: 'normal',
      routes: declared.slice(0, 8).map((d) => `${d.method} ${d.path}`),
      rpcs: [...new Set([...src.matchAll(/\.rpc\(\s*['"`]([a-z0-9_]+)['"`]/gi)].map((m) => m[1]))].slice(0, 10),
      tables: [...new Set([...src.matchAll(/\.from\(\s*['"`]([a-z0-9_]+)['"`]/gi)].map((m) => m[1]))].slice(0, 10),
      externals: [],
      invariants: [{ key: 'TODO', rule: 'À COMPLÉTER : la règle métier vérifiable de cette fonctionnalité' }],
      depends_on: [],
      sources: [`src/routes/${file}`],
    });
  }
}

// ── Verdict ─────────────────────────────────────────────────────────────────
for (const w of warn) console.warn(`⚠️  ${w}`);
for (const e of fail) console.error(`❌ ${e}`);

if (draft.length > 0) {
  console.error(`\n❌ ${draft.length} domaine(s) de routes MAJEURES non mémorisé(s) dans le manifeste.`);
  console.error('   Brouillon généré — complétez les invariants métier puis committez :\n');
  console.error(JSON.stringify({ features: draft }, null, 2));
}

// Sondes : toute sonde doit pointer une feature du manifeste.
for (const p of probes) {
  if (!features.some((f) => f.feature_key === p.feature_key)) {
    fail.push(`sonde « ${p.probe_key} » référence une fonctionnalité inconnue : ${p.feature_key}`);
  }
}

if (fail.length > 0 || draft.length > 0) {
  console.error(`\n❌ check:manifest ÉCHOUE — ${fail.length} erreur(s), ${draft.length} brouillon(s), ${warn.length} avertissement(s).`);
  process.exit(1);
}
console.log(`✅ Manifeste conforme au code : ${features.length} fonctionnalité(s), ${probes.length} sonde(s)${warn.length ? `, ${warn.length} avertissement(s)` : ''}.`);
