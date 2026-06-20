// Test e2e paiement restaurant atomique, en FIXTURE ISOLÉ (restaurant temporaire créé puis supprimé).
//  1) chemin nominal : process → soldes (client -montant, resto +net, PDG +commission)
//  2) idempotence : rejouer la même clé ne re-débite pas
//  3) annulation/remboursement : soldes reviennent à zéro net
//  4) garde atomique : un restaurant au wallet BLOQUÉ refuse la commande SANS débiter le client
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const sb = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});
const RESTAURANT_TYPE = '4aa11ff0-946e-4bc6-9c6a-af73e388868d';
const OWNER = 'aa6fabf2-9048-45e3-8379-ad9301c6de80';   // wallet GNF non bloqué
const CLIENT = '876d385a-a14f-4891-954b-80895ba187b8';  // wallet GNF non bloqué, financé
const BLOCKED_OWNER_SVC = '693c6709-48f7-490d-8db5-110321f972f9'; // Rama (wallet EUR bloqué)
const PRICE = 5000;

const log = (...a) => console.log(...a);
const bal = async (uid) => {
  const { data } = await sb.from('wallets').select('balance').eq('user_id', uid).maybeSingle();
  return Number(data?.balance ?? 0);
};
let svcId = null, itemId = null;

async function cleanup() {
  if (itemId) await sb.from('restaurant_menu_items').delete().eq('id', itemId);
  if (svcId) await sb.from('professional_services').delete().eq('id', svcId);
}

async function main() {
  // ── Fixture : restaurant temporaire (owner propre) + 1 plat. ──
  const { data: svc, error: sErr } = await sb.from('professional_services').insert({
    user_id: OWNER, service_type_id: RESTAURANT_TYPE, business_name: 'E2E TEST RESTO (temp)',
    status: 'active',
  }).select('id').single();
  if (sErr) { log('❌ création service:', sErr.message); process.exit(1); }
  svcId = svc.id;
  const { data: mi, error: mErr } = await sb.from('restaurant_menu_items').insert({
    professional_service_id: svcId, name: 'Plat test', price: PRICE, is_available: true,
  }).select('id').single();
  if (mErr) { log('❌ création plat:', mErr.message); await cleanup(); process.exit(1); }
  itemId = mi.id;
  log(`🍽️  Fixture: resto ${svcId} (owner ${OWNER}) — plat ${PRICE} GNF`);

  const { data: pdg } = await sb.from('pdg_management').select('user_id').eq('is_active', true).limit(1).maybeSingle();
  const pdgId = pdg?.user_id;

  const b0 = { client: await bal(CLIENT), owner: await bal(OWNER), pdg: pdgId ? await bal(pdgId) : 0 };
  log('\n— Soldes AVANT —', b0);

  const idem = `e2e-resto-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  const items = [{ menu_item_id: itemId, name: 'Plat test', quantity: 1, unit_price: PRICE }];
  const callProcess = (key, svc_id) => sb.rpc('process_restaurant_order', {
    p_client_id: CLIENT, p_professional_service_id: svc_id, p_amount: PRICE, p_items: items,
    p_order_type: 'takeaway', p_table_number: null, p_delivery_address: null, p_special_note: 'TEST E2E',
    p_idempotency_key: key,
  });

  // (1) Paiement.
  const { data: pay, error: payErr } = await callProcess(idem, svcId);
  if (payErr) { log('❌ process:', payErr.message); await cleanup(); process.exit(1); }
  log('\n✅ Paiement:', JSON.stringify(pay));
  const orderId = pay.order_id;
  const b1 = { client: await bal(CLIENT), owner: await bal(OWNER), pdg: pdgId ? await bal(pdgId) : 0 };
  log('— APRÈS paiement —', b1);
  log(`   Δclient ${b1.client - b0.client} (attendu -${PRICE}) | Δowner +${(b1.owner - b0.owner).toFixed(2)} (attendu +${PRICE - pay.commission}) | Δpdg +${(b1.pdg - b0.pdg).toFixed(2)} (attendu +${pay.commission})`);

  // (2) Idempotence.
  const { data: pay2 } = await callProcess(idem, svcId);
  const cAfter = await bal(CLIENT);
  log(`\n🔁 Idempotence: ${JSON.stringify(pay2)} | client inchangé ? ${cAfter === b1.client ? '✅' : '❌ ' + cAfter}`);

  // (3) Annulation / remboursement.
  const { data: canc, error: cancErr } = await sb.rpc('cancel_restaurant_order', { p_order_id: orderId, p_reason: 'TEST E2E' });
  if (cancErr) { log('❌ cancel:', cancErr.message); await cleanup(); process.exit(1); }
  log('\n↩️  Annulation:', JSON.stringify(canc));
  const b3 = { client: await bal(CLIENT), owner: await bal(OWNER), pdg: pdgId ? await bal(pdgId) : 0 };
  log('— APRÈS remboursement —', b3);
  const dc = +(b3.client - b0.client).toFixed(2), dow = +(b3.owner - b0.owner).toFixed(2), dp = +(b3.pdg - b0.pdg).toFixed(2);
  log(`   BILAN NET (doit être 0) → client ${dc} | owner ${dow} | pdg ${dp}`);
  const nominalOk = dc === 0 && dow === 0 && dp === 0;

  // (4) Garde atomique : restaurant bloqué refuse SANS débiter le client.
  const cBefore = await bal(CLIENT);
  const { data: blk, error: blkErr } = await callProcess(`e2e-blocked-${Date.now()}`, BLOCKED_OWNER_SVC);
  const cAfterBlk = await bal(CLIENT);
  const guardOk = !!blkErr && cAfterBlk === cBefore;
  log(`\n🛡️  Restaurant bloqué → ${blkErr ? 'REFUSÉ (' + blkErr.message + ')' : 'ACCEPTÉ ❌ ' + JSON.stringify(blk)} | client non débité ? ${cAfterBlk === cBefore ? '✅' : '❌'}`);

  await cleanup();
  log('\n🧹 Fixture nettoyé.');

  const ok = nominalOk && guardOk;
  log(ok ? '\n🎉 SUCCÈS : paiement + idempotence + remboursement atomiques (net 0) ET garde restaurant non créditable.'
        : '\n⚠️  ÉCHEC — voir ci-dessus.');
  process.exit(ok ? 0 : 2);
}

main().catch(async (e) => { console.error('💥', e); await cleanup(); process.exit(1); });
