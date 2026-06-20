// Test e2e : LIVRAISON OFFERTE (le restaurant absorbe les frais). Le client ne paie QUE les plats ;
// à la livraison, le livreur est payé depuis la part du RESTAURANT (98,5 %), marge plateforme au PDG.
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const sb = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const RESTAURANT_TYPE = '4aa11ff0-946e-4bc6-9c6a-af73e388868d';
const OWNER = 'aa6fabf2-9048-45e3-8379-ad9301c6de80';
const CLIENT = '876d385a-a14f-4891-954b-80895ba187b8';
const PRICE = 5000, FEE = 1000, EARNING = Math.round(FEE * 0.985); // 985
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
  const { data: svc } = await sb.from('professional_services').insert({ user_id: OWNER, service_type_id: RESTAURANT_TYPE, business_name: 'E2E OFFERED (temp)', status: 'active' }).select('id').single();
  svcId = svc.id;
  const { data: mi } = await sb.from('restaurant_menu_items').insert({ professional_service_id: svcId, name: 'Plat', price: PRICE, is_available: true }).select('id').single();
  itemId = mi.id;
  const email = `e2e-drv-off-${Date.now()}@test.224solutions.local`;
  const { data: drv } = await sb.auth.admin.createUser({ email, password: `Test!${Math.random().toString(36).slice(2,8)}Aa1`, email_confirm: true });
  driverId = drv.user.id;
  await sb.from('profiles').upsert({ id: driverId, email, role: 'livreur' }, { onConflict: 'id' });
  const { data: pdg } = await sb.from('pdg_management').select('user_id').eq('is_active', true).limit(1).maybeSingle();
  const pdgId = pdg?.user_id;

  const b0 = { client: await bal(CLIENT), owner: await bal(OWNER), pdg: pdgId ? await bal(pdgId) : 0, driver: await bal(driverId) };
  log('— AVANT —', b0);
  let pass = true;

  // (1) Paiement « livraison offerte » : le client NE paie PAS les frais.
  const { data: pay, error: pErr } = await sb.rpc('process_restaurant_order', {
    p_client_id: CLIENT, p_professional_service_id: svcId, p_amount: PRICE,
    p_items: [{ menu_item_id: itemId, name: 'Plat', quantity: 1, unit_price: PRICE }],
    p_order_type: 'delivery', p_table_number: null, p_delivery_address: 'Conakry', p_special_note: null,
    p_idempotency_key: `e2e-off-${Date.now()}`, p_delivery_fee: FEE, p_delivery_paid_by: 'restaurant',
  });
  if (pErr) { log('❌ process:', pErr.message); await cleanup(); process.exit(1); }
  orderId = pay.order_id;
  const dClient1 = (await bal(CLIENT)) - b0.client;
  const ok1 = dClient1 === -PRICE; // client paie seulement les plats
  log(`(1) Offerte — client paie : Δclient=${dClient1} (attendu ${-PRICE}, PAS de frais) → ${ok1 ? '✅' : '❌'}`);
  pass &&= ok1;

  // (2) Livraison → le RESTAURANT absorbe les frais, livreur payé.
  const { data: del } = await sb.from('deliveries').insert({
    restaurant_order_id: orderId, status: 'assigned', driver_id: driverId,
    pickup_address: { name: 'R' }, delivery_address: { a: 'C' }, delivery_fee: 0, package_type: 'restaurant',
  }).select('id').single();
  delivId = del.id;
  const ownerBefore = await bal(OWNER);
  await sb.from('deliveries').update({ status: 'delivered' }).eq('id', delivId);
  await new Promise(r => setTimeout(r, 900));
  const driverAfter = await bal(driverId), ownerAfter = await bal(OWNER);
  const ok2 = (driverAfter - b0.driver === EARNING) && (Math.round(ownerBefore - ownerAfter) === FEE);
  log(`(2) Offerte — livraison : Δlivreur=+${driverAfter - b0.driver} (attendu ${EARNING}) | resto absorbe=-${(ownerBefore - ownerAfter).toFixed(0)} (attendu ${FEE}) → ${ok2 ? '✅' : '❌'}`);
  pass &&= ok2;

  // Bilan global : somme nette = 0 (client + owner + pdg + driver).
  const fin = { client: await bal(CLIENT), owner: await bal(OWNER), pdg: pdgId ? await bal(pdgId) : 0, driver: await bal(driverId) };
  const sum = (fin.client - b0.client) + (fin.owner - b0.owner) + (fin.pdg - b0.pdg) + (fin.driver - b0.driver);
  const ok3 = Math.abs(sum) < 0.01;
  log(`(3) Conservation de l'argent : somme nette = ${sum.toFixed(2)} (attendu 0) → ${ok3 ? '✅' : '❌'}`);
  pass &&= ok3;

  await cleanup();
  log(pass ? '\n🎉 SUCCÈS : livraison offerte — client ne paie pas, resto absorbe, livreur payé, argent conservé.' : '\n⚠️  ÉCHEC.');
  process.exit(pass ? 0 : 2);
}
main().catch(async (e) => { console.error('💥', e); await cleanup(); process.exit(1); });
