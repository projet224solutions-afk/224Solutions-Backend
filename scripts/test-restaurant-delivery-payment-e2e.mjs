// Test e2e du PAIEMENT DE LIVRAISON restaurant (migration 20260616260000).
// Vérifie le circuit d'argent complet : frais payés par le client → séquestre PDG →
// versement au livreur à la livraison (98,5 %) → idempotence.
//
// Fixture : restaurant temporaire (owner GNF non bloqué) + plat ; client GNF financé ;
// livreur jetable. Cleanup complet.
//
// Lancer depuis backend/ :  node scripts/test-restaurant-delivery-payment-e2e.mjs
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const sb = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const RESTAURANT_TYPE = '4aa11ff0-946e-4bc6-9c6a-af73e388868d';
const OWNER = 'aa6fabf2-9048-45e3-8379-ad9301c6de80';   // wallet GNF non bloqué
const CLIENT = '876d385a-a14f-4891-954b-80895ba187b8';  // wallet GNF financé
const PRICE = 5000, FEE = 1000;
const log = (...a) => console.log(...a);
const bal = async (uid) => Number((await sb.from('wallets').select('balance').eq('user_id', uid).maybeSingle()).data?.balance ?? 0);
let svcId = null, itemId = null, orderId = null, delivId = null, driverId = null;

async function cleanup() {
  try { if (delivId) await sb.from('deliveries').delete().eq('id', delivId); } catch {}
  try { if (orderId) await sb.from('restaurant_orders').delete().eq('id', orderId); } catch {}
  try { if (itemId) await sb.from('restaurant_menu_items').delete().eq('id', itemId); } catch {}
  try { if (svcId) await sb.from('professional_services').delete().eq('id', svcId); } catch {}
  try { if (driverId) { await sb.from('profiles').delete().eq('id', driverId); await sb.auth.admin.deleteUser(driverId); } } catch {}
}

async function main() {
  const { data: svc, error: sErr } = await sb.from('professional_services').insert({
    user_id: OWNER, service_type_id: RESTAURANT_TYPE, business_name: 'E2E DELIV PAY (temp)', status: 'active',
  }).select('id').single();
  if (sErr) { log('❌ service:', sErr.message); process.exit(1); }
  svcId = svc.id;
  const { data: mi } = await sb.from('restaurant_menu_items').insert({ professional_service_id: svcId, name: 'Plat', price: PRICE, is_available: true }).select('id').single();
  itemId = mi.id;
  const email = `e2e-driver-${Date.now()}@test.224solutions.local`;
  const { data: drv, error: dErr } = await sb.auth.admin.createUser({ email, password: `Test!${Math.random().toString(36).slice(2,8)}Aa1`, email_confirm: true });
  if (dErr) { log('❌ driver:', dErr.message); await cleanup(); process.exit(1); }
  driverId = drv.user.id;
  await sb.from('profiles').upsert({ id: driverId, email, role: 'livreur' }, { onConflict: 'id' });

  const { data: pdg } = await sb.from('pdg_management').select('user_id').eq('is_active', true).limit(1).maybeSingle();
  const pdgId = pdg?.user_id;
  const b0 = { client: await bal(CLIENT), owner: await bal(OWNER), pdg: pdgId ? await bal(pdgId) : 0, driver: await bal(driverId) };
  log('— Soldes AVANT —', b0);

  let pass = true;

  // (1) Paiement avec frais de livraison (payés par le client).
  const idem = `e2e-deliv-${Date.now()}`;
  const { data: pay, error: pErr } = await sb.rpc('process_restaurant_order', {
    p_client_id: CLIENT, p_professional_service_id: svcId, p_amount: PRICE,
    p_items: [{ menu_item_id: itemId, name: 'Plat', quantity: 1, unit_price: PRICE }],
    p_order_type: 'delivery', p_table_number: null, p_delivery_address: 'Conakry', p_special_note: null,
    p_idempotency_key: idem, p_delivery_fee: FEE, p_delivery_paid_by: 'client',
  });
  if (pErr) { log('❌ process:', pErr.message); await cleanup(); process.exit(1); }
  orderId = pay.order_id;
  const b1 = { client: await bal(CLIENT), owner: await bal(OWNER), pdg: pdgId ? await bal(pdgId) : 0 };
  const dClient = b1.client - b0.client, dPdg = +(b1.pdg - b0.pdg).toFixed(2);
  const ok1 = dClient === -(PRICE + FEE) && Math.round(b1.owner - b0.owner) === Math.round(pay.restaurant_receives);
  log(`(1) Paiement+frais : Δclient=${dClient} (attendu ${-(PRICE+FEE)}) | Δowner=+${(b1.owner-b0.owner).toFixed(0)} (net plats) | Δpdg=+${dPdg} (commission+${FEE} séquestre) → ${ok1 ? '✅' : '❌'}`);
  pass &&= ok1;

  // (2) Livraison : créer la course, l'assigner au livreur, passer « delivered » → trigger paye le livreur.
  const { data: del, error: insErr } = await sb.from('deliveries').insert({
    restaurant_order_id: orderId, status: 'assigned', driver_id: driverId,
    pickup_address: { name: 'Resto' }, delivery_address: { address: 'Conakry' }, delivery_fee: 0, package_type: 'restaurant',
  }).select('id').single();
  if (insErr) { log('❌ deliveries insert:', insErr.message); await cleanup(); process.exit(1); }
  delivId = del.id;
  const pdgBeforePayout = pdgId ? await bal(pdgId) : 0;
  await sb.from('deliveries').update({ status: 'delivered' }).eq('id', delivId);
  await new Promise(r => setTimeout(r, 800)); // laisser le trigger s'exécuter
  const expectedEarning = Math.round(FEE * 0.985); // 985
  const driverAfter = await bal(driverId);
  const pdgAfter = pdgId ? await bal(pdgId) : 0;
  const { data: ord } = await sb.from('restaurant_orders').select('status').eq('id', orderId).single();
  const ok2 = driverAfter - b0.driver === expectedEarning && Math.round(pdgBeforePayout - pdgAfter) === expectedEarning && ord?.status === 'completed';
  log(`(2) Livraison→versement : Δlivreur=+${driverAfter - b0.driver} (attendu ${expectedEarning}) | PDG payout=-${(pdgBeforePayout - pdgAfter).toFixed(0)} | commande=${ord?.status} → ${ok2 ? '✅' : '❌'}`);
  pass &&= ok2;

  // (3) Idempotence : re-verser ne re-paie pas.
  const { data: again } = await sb.rpc('pay_restaurant_delivery', { p_delivery_id: delivId });
  const driverAfter2 = await bal(driverId);
  const ok3 = (again?.already_paid === true) && driverAfter2 === driverAfter;
  log(`(3) Idempotence versement : ${JSON.stringify(again)} | livreur inchangé ? ${driverAfter2 === driverAfter ? '✅' : '❌'} → ${ok3 ? '✅' : '❌'}`);
  pass &&= ok3;

  await cleanup();
  log('\n🧹 Fixture nettoyée.');
  log(pass ? '\n🎉 SUCCÈS : frais client → séquestre → livreur (98,5%), idempotent, commande clôturée.' : '\n⚠️  ÉCHEC — voir ci-dessus.');
  process.exit(pass ? 0 : 2);
}

main().catch(async (e) => { console.error('💥', e); await cleanup(); process.exit(1); });
