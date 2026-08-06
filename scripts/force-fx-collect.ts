/**
 * 👻 Collecte FX forcée (le même chemin que POST /api/fx/collect-now).
 * Usage : npx tsx scripts/force-fx-collect.ts
 */
import 'dotenv/config';
import { collectAfricanRates, materializeCrossRates } from '../src/services/fxRates.service.js';

const run = async () => {
  const r = await collectAfricanRates();
  console.log(`[FORCE-FX] ok=${r.ok} fallback=${r.fallback} cached=${r.cached} failed=${r.failed} en ${r.durationMs}ms`);
  const crosses = await materializeCrossRates();
  console.log(`[FORCE-FX] croisés matérialisés: ${crosses}`);
  process.exit(0);
};
run().catch((e) => { console.error('[FORCE-FX] ÉCHEC:', e.message); process.exit(1); });
