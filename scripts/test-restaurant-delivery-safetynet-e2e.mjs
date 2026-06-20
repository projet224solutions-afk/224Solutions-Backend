// Test e2e du FILET DE SÉCURITÉ : accepter une commande livraison par UPDATE direct (simule le repli
// Supabase quand le backend est injoignable) DOIT créer la course `deliveries` via le trigger DB.
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const sb = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const RESTAURANT_TYPE = '4aa11ff0-946e-4bc6-9c6a-af73e388868d';
const OWNER = 'aa6fabf2-9048-45e3-8379-ad9301c6de80';
const CLIENT = '876d385a-a14f-4891-954b-80895ba187b8';
const PRICE = 5000;
const log = (...a) => console.log(...a);
let svcId = null, itemId = null, orderId = null;

async function cleanup() {
  try { if (orderId) await sb.from('deliveries').delete().eq('restaurant_order_id', orderId); } catch {}
  try { if (orderId) await sb.from('restaurant_orders').delete().eq('id', orderId); } catch {}
  try { if (itemId) await sb.from('restaurant_menu_items').delete().eq('id', itemId); } catch {}
  try { if (svcId) await sb.from('professional_services').delete().eq('id', svcId); } catch {}
}
const courseCount = async () => (await sb.from('deliveries').select('id', { count: 'exact', head: true }).eq('restaurant_order_id', orderId)).count || 0;

async function main() {
  const { data: svc } = await sb.from('professional_services').insert({ user_id: OWNER, service_type_id: RESTAURANT_TYPE, business_name: 'E2E SAFETYNET (temp)', status: 'active', latitude: 9.64, longitude: -13.58 }).select('id').single();
  svcId = svc.id;
  const { data: mi } = await sb.from('restaurant_menu_items').insert({ professional_service_id: svcId, name: 'Plat', price: PRICE, is_available: true }).select('id').single();
  itemId = mi.id;

  // Commande livraison payée (status 'pending' → pas encore de course).
  const { data: pay, error: pErr } = await sb.rpc('process_restaurant_order', {
    p_client_id: CLIENT, p_professional_service_id: svcId, p_amount: PRICE,
    p_items: [{ menu_item_id: itemId, name: 'Plat', quantity: 1, unit_price: PRICE }],
    p_order_type: 'delivery', p_table_number: null, p_delivery_address: 'Kaloum, Conakry', p_special_note: null,
    p_idempotency_key: `e2e-net-${Date.now()}`, p_delivery_fee: 800, p_delivery_paid_by: 'client',
  });
  if (pErr) { log('❌ process:', pErr.message); await cleanup(); process.exit(1); }
  orderId = pay.order_id;
  let pass = true;

  const before = await courseCount();
  const ok0 = before === 0;
  log(`(0) Avant acceptation : ${before} course (attendu 0) → ${ok0 ? '✅' : '❌'}`);
  pass &&= ok0;

  // ACCEPTATION PAR UPDATE DIRECT (simule le repli, SANS backend ensureRestaurantDelivery).
  await sb.from('restaurant_orders').update({ status: 'preparing' }).eq('id', orderId);
  await new Promise(r => setTimeout(r, 500));
  const after = await courseCount();
  const { data: course } = await sb.from('deliveries').select('status, package_type, client_id, delivery_address').eq('restaurant_order_id', orderId).maybeSingle();
  const ok1 = after === 1 && course?.status === 'pending' && course?.package_type === 'restaurant' && course?.client_id === CLIENT;
  log(`(1) Repli (update direct) → course créée : ${after} course | status=${course?.status} | type=${course?.package_type} | adresse=${JSON.stringify(course?.delivery_address?.text)} → ${ok1 ? '✅' : '❌'}`);
  pass &&= ok1;

  // IDEMPOTENCE : un autre changement de statut ne crée pas de doublon.
  await sb.from('restaurant_orders').update({ status: 'ready' }).eq('id', orderId);
  await new Promise(r => setTimeout(r, 500));
  const after2 = await courseCount();
  const ok2 = after2 === 1;
  log(`(2) Idempotence (preparing→ready) : ${after2} course (attendu 1, pas de doublon) → ${ok2 ? '✅' : '❌'}`);
  pass &&= ok2;

  await cleanup();
  log(pass ? '\n🎉 SUCCÈS : course créée par le filet DB quel que soit le chemin, sans doublon.' : '\n⚠️  ÉCHEC.');
  process.exit(pass ? 0 : 2);
}
main().catch(async (e) => { console.error('💥', e); await cleanup(); process.exit(1); });
