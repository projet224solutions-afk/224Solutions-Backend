// Test e2e : ANNULATION d'une commande livraison payée → le client doit être remboursé
// INTÉGRALEMENT (plats + frais de livraison séquestrés). Prouve/valide le remboursement des frais.
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const sb = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const RESTAURANT_TYPE = '4aa11ff0-946e-4bc6-9c6a-af73e388868d';
const OWNER = 'aa6fabf2-9048-45e3-8379-ad9301c6de80';
const CLIENT = '876d385a-a14f-4891-954b-80895ba187b8';
const PRICE = 5000, FEE = 1000;
const log = (...a) => console.log(...a);
const bal = async (uid) => Number((await sb.from('wallets').select('balance').eq('user_id', uid).maybeSingle()).data?.balance ?? 0);
let svcId = null, itemId = null, orderId = null;

async function cleanup() {
  try { if (orderId) await sb.from('restaurant_orders').delete().eq('id', orderId); } catch {}
  try { if (itemId) await sb.from('restaurant_menu_items').delete().eq('id', itemId); } catch {}
  try { if (svcId) await sb.from('professional_services').delete().eq('id', svcId); } catch {}
}

async function main() {
  const { data: svc } = await sb.from('professional_services').insert({ user_id: OWNER, service_type_id: RESTAURANT_TYPE, business_name: 'E2E REFUND (temp)', status: 'active' }).select('id').single();
  svcId = svc.id;
  const { data: mi } = await sb.from('restaurant_menu_items').insert({ professional_service_id: svcId, name: 'Plat', price: PRICE, is_available: true }).select('id').single();
  itemId = mi.id;
  const { data: pdg } = await sb.from('pdg_management').select('user_id').eq('is_active', true).limit(1).maybeSingle();
  const pdgId = pdg?.user_id;

  const b0 = { client: await bal(CLIENT), owner: await bal(OWNER), pdg: pdgId ? await bal(pdgId) : 0 };
  log('— AVANT —', b0);

  // Paiement livraison avec frais payés par le client.
  const { data: pay, error: pErr } = await sb.rpc('process_restaurant_order', {
    p_client_id: CLIENT, p_professional_service_id: svcId, p_amount: PRICE,
    p_items: [{ menu_item_id: itemId, name: 'Plat', quantity: 1, unit_price: PRICE }],
    p_order_type: 'delivery', p_table_number: null, p_delivery_address: 'Conakry', p_special_note: null,
    p_idempotency_key: `e2e-refund-${Date.now()}`, p_delivery_fee: FEE, p_delivery_paid_by: 'client',
  });
  if (pErr) { log('❌ process:', pErr.message); await cleanup(); process.exit(1); }
  orderId = pay.order_id;
  const b1 = { client: await bal(CLIENT) };
  log(`Payé : Δclient=${b1.client - b0.client} (attendu ${-(PRICE + FEE)})`);

  // Annulation (ex : restaurant refuse).
  const { error: cErr } = await sb.rpc('cancel_restaurant_order', { p_order_id: orderId, p_reason: 'Test refund' });
  if (cErr) { log('❌ cancel:', cErr.message); await cleanup(); process.exit(1); }

  const b2 = { client: await bal(CLIENT), owner: await bal(OWNER), pdg: pdgId ? await bal(pdgId) : 0 };
  const dClient = +(b2.client - b0.client).toFixed(2), dOwner = +(b2.owner - b0.owner).toFixed(2), dPdg = +(b2.pdg - b0.pdg).toFixed(2);
  log('— APRÈS annulation — bilan NET (doit être 0 partout) :');
  log(`   client ${dClient} | owner ${dOwner} | pdg ${dPdg}`);
  const ok = dClient === 0 && dOwner === 0 && dPdg === 0;
  log(ok
    ? '\n🎉 SUCCÈS : remboursement intégral (plats + frais de livraison), net 0 partout.'
    : `\n⚠️  ÉCHEC : le client n'est pas intégralement remboursé (perte = ${-dClient} GNF, probablement les frais de livraison non remboursés).`);

  await cleanup();
  process.exit(ok ? 0 : 2);
}
main().catch(async (e) => { console.error('💥', e); await cleanup(); process.exit(1); });
