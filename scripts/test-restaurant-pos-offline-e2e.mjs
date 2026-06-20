// Test e2e de la CAISSE RESTAURANT HORS LIGNE (RPC create_restaurant_pos_offline_order),
// en FIXTURE ISOLÉ : utilisateur de test jetable + restaurant temporaire + plat, puis cleanup.
//
// Vérifie les garanties de la migration 20260616230000 :
//   1) CRÉATION : la vente offline rejouée crée la commande (source 'pos_offline') + décrémente le stock.
//   2) IDEMPOTENCE : rejouer le MÊME order_number → 'duplicate', AUCUNE 2ᵉ ligne, AUCUN re-décrément.
//   3) STOCK BEST-EFFORT : une quantité > stock NE LÈVE PAS (vente déjà encaissée) → stock clampé à 0.
//   4) SÉCURITÉ : un appel sans session propriétaire (service-role, auth.uid NULL) → refusé NON_AUTORISE.
//
// La RPC exige auth.uid() = propriétaire du service → le script s'authentifie RÉELLEMENT en tant que
// propriétaire de test (createUser + signInWithPassword), comme le ferait le restaurateur.
//
// Lancer depuis backend/ :  node scripts/test-restaurant-pos-offline-e2e.mjs
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const URL = process.env.SUPABASE_URL;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const ANON_KEY = process.env.SUPABASE_ANON_KEY;
if (!URL || !SERVICE_KEY || !ANON_KEY) {
  console.error('❌ SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / SUPABASE_ANON_KEY requis dans backend/.env');
  process.exit(1);
}

const sb = createClient(URL, SERVICE_KEY, { auth: { persistSession: false } });
const RESTAURANT_TYPE = '4aa11ff0-946e-4bc6-9c6a-af73e388868d';
const PRICE = 5000;
const log = (...a) => console.log(...a);

let testUserId = null, svcId = null, itemId = null;
const email = `e2e-pos-offline-${Date.now()}@test.224solutions.local`;
const password = `Test!${Math.random().toString(36).slice(2, 10)}Aa1`;

async function stockOf(id) {
  const { data } = await sb.from('restaurant_menu_items').select('stock_quantity, is_available').eq('id', id).single();
  return data;
}
async function offlineOrderCount() {
  const { count } = await sb.from('restaurant_orders')
    .select('id', { count: 'exact', head: true })
    .eq('professional_service_id', svcId).eq('source', 'pos_offline');
  return count || 0;
}
function posPayload(orderNumber, qty) {
  return {
    p_service_id: svcId,
    p_order_number: orderNumber,
    p_order: {
      order_type: 'dine_in', status: 'completed', customer_name: 'Client E2E',
      payment_method: 'cash', payment_status: 'paid',
      subtotal: PRICE * qty, tax: 0, discount_amount: 0, total: PRICE * qty,
      items: [{ menu_item_id: itemId, name: 'Plat test', price: PRICE, quantity: qty, subtotal: PRICE * qty }],
      created_at: new Date().toISOString(),
    },
  };
}

async function cleanup() {
  try { if (svcId) await sb.from('restaurant_orders').delete().eq('professional_service_id', svcId).eq('source', 'pos_offline'); } catch {}
  try { if (itemId) await sb.from('restaurant_menu_items').delete().eq('id', itemId); } catch {}
  try { if (svcId) await sb.from('professional_services').delete().eq('id', svcId); } catch {}
  try { if (testUserId) await sb.from('profiles').delete().eq('id', testUserId); } catch {}
  try { if (testUserId) await sb.auth.admin.deleteUser(testUserId); } catch {}
}

async function main() {
  // ── Fixture : utilisateur jetable + profil + restaurant temporaire + plat (stock 3). ──
  const { data: created, error: cErr } = await sb.auth.admin.createUser({ email, password, email_confirm: true });
  if (cErr) { log('❌ createUser:', cErr.message); process.exit(1); }
  testUserId = created.user.id;
  await sb.from('profiles').upsert({ id: testUserId, email, role: 'vendeur', full_name: 'E2E Resto Owner' }, { onConflict: 'id' });

  const { data: svc, error: sErr } = await sb.from('professional_services').insert({
    user_id: testUserId, service_type_id: RESTAURANT_TYPE, business_name: 'E2E POS OFFLINE (temp)', status: 'active',
  }).select('id').single();
  if (sErr) { log('❌ création service:', sErr.message); await cleanup(); process.exit(1); }
  svcId = svc.id;

  const { data: mi, error: mErr } = await sb.from('restaurant_menu_items').insert({
    professional_service_id: svcId, name: 'Plat test', price: PRICE, is_available: true, stock_quantity: 3,
  }).select('id').single();
  if (mErr) { log('❌ création plat:', mErr.message); await cleanup(); process.exit(1); }
  itemId = mi.id;
  log(`🍽️  Fixture : resto ${svcId} (owner ${testUserId}) — plat ${PRICE} GNF, stock 3`);

  // ── Session RÉELLE du propriétaire (comme le restaurateur connecté). ──
  const owner = createClient(URL, ANON_KEY, { auth: { persistSession: false } });
  const { error: signErr } = await owner.auth.signInWithPassword({ email, password });
  if (signErr) { log('❌ signIn owner:', signErr.message); await cleanup(); process.exit(1); }

  let pass = true;

  // (1) CRÉATION + décrément stock.
  const { data: r1, error: e1 } = await owner.rpc('create_restaurant_pos_offline_order', posPayload('RESTO-OFF-E2E-1', 2));
  const s1 = await stockOf(itemId);
  const count1 = await offlineOrderCount();
  const ok1 = !e1 && r1?.status === 'created' && count1 === 1 && s1?.stock_quantity === 1;
  log(`\n(1) Création : ${e1 ? '❌ ' + e1.message : JSON.stringify(r1)} | commandes=${count1} | stock 3→${s1?.stock_quantity} (attendu 1) → ${ok1 ? '✅' : '❌'}`);
  pass &&= ok1;

  // (2) IDEMPOTENCE : même order_number → duplicate, pas de 2ᵉ ligne, pas de re-décrément.
  const { data: r2, error: e2 } = await owner.rpc('create_restaurant_pos_offline_order', posPayload('RESTO-OFF-E2E-1', 2));
  const s2 = await stockOf(itemId);
  const count2 = await offlineOrderCount();
  const ok2 = !e2 && r2?.status === 'duplicate' && count2 === 1 && s2?.stock_quantity === 1;
  log(`(2) Idempotence : ${e2 ? '❌ ' + e2.message : JSON.stringify(r2)} | commandes=${count2} (attendu 1) | stock=${s2?.stock_quantity} (inchangé 1) → ${ok2 ? '✅' : '❌'}`);
  pass &&= ok2;

  // (3) STOCK BEST-EFFORT : qty 5 > stock 1 → NE LÈVE PAS, stock clampé à 0 + indisponible.
  const { data: r3, error: e3 } = await owner.rpc('create_restaurant_pos_offline_order', posPayload('RESTO-OFF-E2E-2', 5));
  const s3 = await stockOf(itemId);
  const ok3 = !e3 && r3?.status === 'created' && s3?.stock_quantity === 0 && s3?.is_available === false;
  log(`(3) Stock best-effort : ${e3 ? '❌ ' + e3.message : JSON.stringify(r3)} | stock 1→${s3?.stock_quantity} (attendu 0) | dispo=${s3?.is_available} (attendu false) → ${ok3 ? '✅' : '❌'}`);
  pass &&= ok3;

  // (4) SÉCURITÉ : appel sans session propriétaire (service-role, auth.uid NULL) → NON_AUTORISE.
  const { data: r4, error: e4 } = await sb.rpc('create_restaurant_pos_offline_order', posPayload('RESTO-OFF-E2E-HACK', 1));
  const ok4 = !!e4 && /NON_AUTORISE/.test(e4.message);
  log(`(4) Sécurité (sans owner) : ${e4 ? 'REFUSÉ (' + e4.message + ')' : 'ACCEPTÉ ❌ ' + JSON.stringify(r4)} → ${ok4 ? '✅' : '❌'}`);
  pass &&= ok4;

  await owner.auth.signOut();
  await cleanup();
  log('\n🧹 Fixture nettoyé.');
  log(pass
    ? '\n🎉 SUCCÈS : caisse restaurant offline = création + idempotence + stock best-effort + sécurité OK.'
    : '\n⚠️  ÉCHEC — voir ci-dessus.');
  process.exit(pass ? 0 : 2);
}

main().catch(async (e) => { console.error('💥', e); await cleanup(); process.exit(1); });
