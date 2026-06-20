// Test e2e — Livraison pharmacie mutualisée (pont deliveries + auto-course + versement livreur).
// Prérequis : migrations 20260617150000 + 20260617160000 appliquées.
//   1) Payer une ordonnance « livraison » → commande preparing → course créée AUTOMATIQUEMENT.
//   2) Livreur assigné + course 'delivered' → commande passe 'delivered' + livreur payé 98,5% des frais.
//   3) Idempotence : pas de double versement.
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const sb = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const PHARMA_TYPE = 'b8f7e6d5-c4a3-4b21-9e0f-1a2b3c4d5e6f';
const OWNER = 'aa6fabf2-9048-45e3-8379-ad9301c6de80';
const CLIENT = '876d385a-a14f-4891-954b-80895ba187b8';
const PRICE = 5000, DFEE = 2000;
const log = (...a) => console.log(...a);
const ok = (c, m) => { log(`${c ? '✅' : '❌'} ${m}`); return c; };
const bal = async (uid) => Number((await sb.from('wallets').select('balance').eq('user_id', uid).maybeSingle()).data?.balance ?? 0);

let svcId = null, prescId = null, driverId = null, deliveryId = null, orderId = null;
async function cleanup() {
  try { if (deliveryId) await sb.from('deliveries').delete().eq('id', deliveryId); } catch {}
  try { if (svcId) await sb.from('pharmacy_orders').delete().eq('pharmacy_id', svcId); } catch {}
  try { if (svcId) await sb.from('prescriptions').delete().eq('pharmacy_id', svcId); } catch {}
  try { if (svcId) await sb.from('professional_services').delete().eq('id', svcId); } catch {}
  try { if (driverId) await sb.auth.admin.deleteUser(driverId); } catch {}
}

async function main() {
  // Driver jetable.
  const email = `e2e-driver-${Date.now()}@t.io`;
  const { data: drv, error: dErr } = await sb.auth.admin.createUser({ email, password: 'Test1234!', email_confirm: true });
  if (dErr) { log('❌ driver:', dErr.message); process.exit(1); }
  driverId = drv.user.id;

  const { data: svc } = await sb.from('professional_services').insert({ user_id: OWNER, service_type_id: PHARMA_TYPE, business_name: 'E2E PHARMA DELIV (temp)', status: 'active', address: 'Rue Test', latitude: 9.5, longitude: -13.7 }).select('id').single();
  svcId = svc.id;
  const meds = [{ name: 'Amoxicilline', dosage: '500mg', quantity: 1, price: PRICE }];
  const { data: p } = await sb.from('prescriptions').insert({ client_id: CLIENT, pharmacy_id: svcId, photos: ['x'], status: 'quoted', medications_validated: meds, total_quoted: PRICE, delivery_type: 'delivery', delivery_address: '123 Avenue Test', delivery_fee: DFEE }).select('id').single();
  prescId = p.id;

  let pass = true;

  // (1) Paiement « livraison » → commande + course auto.
  const { data: pay, error: pErr } = await sb.rpc('process_pharmacy_order', {
    p_client_id: CLIENT, p_pharmacy_id: svcId, p_prescription_id: prescId, p_amount: PRICE, p_medications: meds,
    p_delivery_type: 'delivery', p_delivery_address: '123 Avenue Test', p_idempotency_key: `e2e-deliv-${Date.now()}`,
    p_delivery_fee: DFEE, p_delivery_paid_by: 'client',
  });
  if (pErr) { log('❌ process:', pErr.message); await cleanup(); process.exit(1); }
  orderId = pay.order_id;
  const { data: deliv } = await sb.from('deliveries').select('*').eq('pharmacy_order_id', orderId).maybeSingle();
  deliveryId = deliv?.id;
  pass &= ok(!!deliv && deliv.status === 'pending' && Number(deliv.delivery_fee) === DFEE && deliv.package_type === 'pharmacy',
    `(1) Course créée auto (status=${deliv?.status}, frais=${deliv?.delivery_fee}, type=${deliv?.package_type})`);

  // (2) Livreur assigné + livraison confirmée → commande delivered + paiement livreur.
  const drvBefore = await bal(driverId);
  await sb.from('deliveries').update({ driver_id: driverId, status: 'delivered' }).eq('id', deliveryId);
  await new Promise((r) => setTimeout(r, 400)); // laisser les triggers s'exécuter
  const { data: ord } = await sb.from('pharmacy_orders').select('status').eq('id', orderId).maybeSingle();
  const { data: dRow } = await sb.from('deliveries').select('driver_paid_at, driver_earning').eq('id', deliveryId).maybeSingle();
  const drvAfter = await bal(driverId);
  const expectedEarning = Math.round(DFEE * 0.985);
  pass &= ok(ord?.status === 'delivered', `(2a) Commande passée 'delivered' (=${ord?.status})`);
  pass &= ok(drvAfter - drvBefore === expectedEarning && !!dRow?.driver_paid_at,
    `(2b) Livreur payé +${drvAfter - drvBefore} (attendu ${expectedEarning}), driver_paid_at=${!!dRow?.driver_paid_at}`);

  // (3) Idempotence du versement.
  const r3 = await sb.rpc('pay_pharmacy_delivery', { p_delivery_id: deliveryId });
  const drvAfter2 = await bal(driverId);
  pass &= ok(drvAfter2 === drvAfter && (r3.data?.already_paid === true), `(3) Pas de double versement (already_paid=${r3.data?.already_paid}, solde inchangé=${drvAfter2 === drvAfter})`);

  await cleanup();
  log(pass ? '\n🎉 SUCCÈS : livraison pharmacie mutualisée (course auto + versement livreur 98,5% + idempotent).' : '\n⚠️  ÉCHEC.');
  process.exit(pass ? 0 : 2);
}
main().catch(async (e) => { console.error('💥', e); await cleanup(); process.exit(1); });
