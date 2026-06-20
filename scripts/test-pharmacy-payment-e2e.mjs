// Test e2e Phase 2 pharmacie : paiement atomique process_pharmacy_order.
//   1) Paiement d'une ordonnance VALIDÉE → débit client, crédit pharmacie net, commission PDG.
//   2) Idempotence : rejeu de la clé → pas de double débit.
//   3) GARDE MÉDICALE : ordonnance NON validée (pending) → refus ORDONNANCE_NON_VALIDEE.
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const sb = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const PHARMA_TYPE = 'b8f7e6d5-c4a3-4b21-9e0f-1a2b3c4d5e6f';
const OWNER = 'aa6fabf2-9048-45e3-8379-ad9301c6de80';   // wallet GNF non bloqué
const CLIENT = '876d385a-a14f-4891-954b-80895ba187b8';  // wallet GNF financé
const PRICE = 5000;
const log = (...a) => console.log(...a);
const bal = async (uid) => Number((await sb.from('wallets').select('balance').eq('user_id', uid).maybeSingle()).data?.balance ?? 0);
let svcId = null, prescOk = null, prescBad = null, orderId = null;

async function cleanup() {
  try { if (svcId) await sb.from('pharmacy_orders').delete().eq('pharmacy_id', svcId); } catch {}
  try { if (svcId) await sb.from('prescriptions').delete().eq('pharmacy_id', svcId); } catch {}
  try { if (svcId) await sb.from('professional_services').delete().eq('id', svcId); } catch {}
}

async function main() {
  const { data: svc, error: sErr } = await sb.from('professional_services').insert({ user_id: OWNER, service_type_id: PHARMA_TYPE, business_name: 'E2E PHARMA PAY (temp)', status: 'active' }).select('id').single();
  if (sErr) { log('❌ service:', sErr.message); process.exit(1); }
  svcId = svc.id;
  // Ordonnance VALIDÉE (devis prêt) + une ordonnance NON validée (pending).
  const meds = [{ name: 'Paracétamol', dosage: '500mg', quantity: 2, price: 2500 }];
  const { data: p1 } = await sb.from('prescriptions').insert({ client_id: CLIENT, pharmacy_id: svcId, photos: ['x'], status: 'quoted', medications_validated: meds, total_quoted: PRICE }).select('id').single();
  prescOk = p1.id;
  const { data: p2 } = await sb.from('prescriptions').insert({ client_id: CLIENT, pharmacy_id: svcId, photos: ['x'], status: 'pending' }).select('id').single();
  prescBad = p2.id;

  const { data: pdg } = await sb.from('pdg_management').select('user_id').eq('is_active', true).limit(1).maybeSingle();
  const pdgId = pdg?.user_id;
  const b0 = { client: await bal(CLIENT), owner: await bal(OWNER), pdg: pdgId ? await bal(pdgId) : 0 };
  log('— AVANT —', b0);
  let pass = true;

  // (1) Paiement de l'ordonnance validée.
  const idem = `e2e-pharma-${Date.now()}`;
  const { data: pay, error: pErr } = await sb.rpc('process_pharmacy_order', {
    p_client_id: CLIENT, p_pharmacy_id: svcId, p_prescription_id: prescOk, p_amount: PRICE,
    p_medications: meds, p_delivery_type: 'pickup', p_delivery_address: null, p_idempotency_key: idem,
  });
  if (pErr) { log('❌ process:', pErr.message); await cleanup(); process.exit(1); }
  orderId = pay.order_id;
  const b1 = { client: await bal(CLIENT), owner: await bal(OWNER), pdg: pdgId ? await bal(pdgId) : 0 };
  const dC = b1.client - b0.client, dO = +(b1.owner - b0.owner).toFixed(2), dP = +(b1.pdg - b0.pdg).toFixed(2);
  const ok1 = dC === -PRICE && dO === PRICE && dP === 0;
  log(`(1) Paiement : Δclient=${dC} (attendu ${-PRICE}) | Δpharmacie=+${dO} (intégral, attendu ${PRICE}) | Δpdg=+${dP} (commission, attendu 0) → ${ok1 ? '✅' : '❌'}`);
  pass &&= ok1;

  // (2) Idempotence : rejeu.
  const { data: pay2 } = await sb.rpc('process_pharmacy_order', {
    p_client_id: CLIENT, p_pharmacy_id: svcId, p_prescription_id: prescOk, p_amount: PRICE,
    p_medications: meds, p_delivery_type: 'pickup', p_delivery_address: null, p_idempotency_key: idem,
  });
  const cAfter = await bal(CLIENT);
  const ok2 = (pay2?.idempotent === true || pay2?.order_id === orderId) && cAfter === b1.client;
  log(`(2) Idempotence : ${JSON.stringify(pay2)} | client inchangé ? ${cAfter === b1.client ? '✅' : '❌'} → ${ok2 ? '✅' : '❌'}`);
  pass &&= ok2;

  // (3) GARDE MÉDICALE : ordonnance non validée → refus.
  const cBefore = await bal(CLIENT);
  const { error: e3 } = await sb.rpc('process_pharmacy_order', {
    p_client_id: CLIENT, p_pharmacy_id: svcId, p_prescription_id: prescBad, p_amount: PRICE,
    p_medications: [], p_delivery_type: 'pickup', p_delivery_address: null, p_idempotency_key: `e2e-bad-${Date.now()}`,
  });
  const cAfterBad = await bal(CLIENT);
  const ok3 = !!e3 && /ORDONNANCE_NON_VALIDEE/.test(e3.message) && cAfterBad === cBefore;
  log(`(3) Garde médicale (ordonnance pending) : ${e3 ? 'REFUSÉ (' + e3.message + ')' : '❌ AUTORISÉ (faille !)'} | client non débité ? ${cAfterBad === cBefore ? '✅' : '❌'} → ${ok3 ? '✅' : '❌'}`);
  pass &&= ok3;

  await cleanup();
  log(pass ? '\n🎉 SUCCÈS : paiement pharmacie atomique + idempotent + garde médicale (ordonnance validée obligatoire).' : '\n⚠️  ÉCHEC.');
  process.exit(pass ? 0 : 2);
}
main().catch(async (e) => { console.error('💥', e); await cleanup(); process.exit(1); });
