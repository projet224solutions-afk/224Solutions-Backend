// Test e2e RÉEL du calcul des frais par DISTANCE : appelle l'endpoint HTTP /api/v2/restaurant/order
// avec des coordonnées client et vérifie que delivery_fee == base resto + 2000/km × distance(resto→client).
// Prérequis : backend lancé (npm --prefix backend run dev) sur le port 3001.
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const API = process.env.TEST_API_URL || 'http://localhost:3001';
const sb = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const RESTAURANT_TYPE = '4aa11ff0-946e-4bc6-9c6a-af73e388868d';
const PRICE = 5000, BASE_FEE = 1500, PER_KM = 2000;
// Coordonnées fixes (Conakry) → distance déterministe.
const RESTO = { lat: 9.6000, lng: -13.6000 };
const CLIENT_POS = { lat: 9.6200, lng: -13.6200 };
const log = (...a) => console.log(...a);

function haversineKm(lat1, lng1, lat2, lng2) {
  const R = 6371, toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1), dLng = toRad(lng2 - lng1);
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

let svcId = null, itemId = null, orderId = null, clientId = null;
const email = `e2e-dist-${Date.now()}@test.224solutions.local`;
const password = `Test!${Math.random().toString(36).slice(2, 10)}Aa1`;

async function cleanup() {
  try { if (orderId) { await sb.from('deliveries').delete().eq('restaurant_order_id', orderId); await sb.from('restaurant_orders').delete().eq('id', orderId); } } catch {}
  try { if (itemId) await sb.from('restaurant_menu_items').delete().eq('id', itemId); } catch {}
  try { if (svcId) await sb.from('professional_services').delete().eq('id', svcId); } catch {}
  try { if (clientId) { await sb.from('profiles').delete().eq('id', clientId); await sb.auth.admin.deleteUser(clientId); } } catch {}
}

async function main() {
  // Santé backend.
  try { const h = await fetch(`${API}/healthz.json`); if (!h.ok) throw 0; } catch {
    log(`❌ Backend injoignable sur ${API}. Lancez : npm --prefix backend run dev`); process.exit(1);
  }

  // Owner jetable (pour pouvoir supprimer le service ensuite) + service géolocalisé + plat.
  const ownerEmail = `e2e-distowner-${Date.now()}@test.224solutions.local`;
  const { data: owner } = await sb.auth.admin.createUser({ email: ownerEmail, password, email_confirm: true });
  await sb.from('profiles').upsert({ id: owner.user.id, email: ownerEmail, role: 'vendeur' }, { onConflict: 'id' });
  await sb.rpc('credit_user_wallet_safe', { p_user_id: owner.user.id, p_amount: 100, p_currency: 'GNF' }).then(() => {}, () => {}); // assure un wallet resto non bloqué
  const { data: svc, error: sErr } = await sb.from('professional_services').insert({
    user_id: owner.user.id, service_type_id: RESTAURANT_TYPE, business_name: 'E2E DISTANCE (temp)', status: 'active',
    latitude: RESTO.lat, longitude: RESTO.lng, metadata: { delivery_fee: BASE_FEE },
  }).select('id').single();
  if (sErr) { log('❌ service:', sErr.message); await cleanup(); process.exit(1); }
  svcId = svc.id; clientId = owner.user.id; // cleanup owner via clientId slot? non — gérer séparément
  const { data: mi } = await sb.from('restaurant_menu_items').insert({ professional_service_id: svcId, name: 'Plat', price: PRICE, is_available: true }).select('id').single();
  itemId = mi.id;

  // Acheteur = compte de test DÉJÀ financé (solde dépensable, hors quarantaine AML), comme les autres
  // tests delivery. On lui pose un mot de passe temporaire pour obtenir un token Supabase.
  const BUYER = '876d385a-a14f-4891-954b-80895ba187b8';
  const buyerId = BUYER;
  const { data: bu } = await sb.auth.admin.getUserById(BUYER);
  const buyerEmail = bu?.user?.email;
  await sb.auth.admin.updateUserById(BUYER, { password });
  const anon = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_ANON_KEY, { auth: { persistSession: false } });
  const { data: sess, error: sgErr } = await anon.auth.signInWithPassword({ email: buyerEmail, password });
  if (sgErr) { log('❌ signIn:', sgErr.message); await sb.from('professional_services').delete().eq('id', svcId); await sb.from('restaurant_menu_items').delete().eq('id', itemId); await sb.auth.admin.deleteUser(owner.user.id); process.exit(1); }
  const token = sess.session.access_token;

  // Appel RÉEL de l'endpoint avec les coordonnées du client.
  const resp = await fetch(`${API}/api/v2/restaurant/order`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify({
      professional_service_id: svcId, order_type: 'delivery',
      items: [{ menu_item_id: itemId, quantity: 1 }],
      delivery_address: 'Test', client_lat: CLIENT_POS.lat, client_lng: CLIENT_POS.lng,
      idempotency_key: `e2e-dist-${Date.now()}`,
    }),
  });
  const body = await resp.json();
  orderId = body.order_id || null;

  const dist = haversineKm(RESTO.lat, RESTO.lng, CLIENT_POS.lat, CLIENT_POS.lng);
  const expectedFee = Math.round(BASE_FEE + PER_KM * dist);
  const ok1 = body.success === true && body.delivery_fee === expectedFee;
  log(`Distance resto→client ≈ ${dist.toFixed(2)} km`);
  log(`Frais attendus = ${BASE_FEE} + ${PER_KM}×${dist.toFixed(2)} = ${expectedFee} GNF`);
  log(`Endpoint a renvoyé delivery_fee = ${body.delivery_fee} | charged = ${body.charged} → ${ok1 ? '✅' : '❌'}`);
  const ok2 = body.charged === PRICE + expectedFee;
  log(`Montant débité (plats ${PRICE} + frais ${expectedFee}) = ${PRICE + expectedFee} → ${ok2 ? '✅' : '❌'}`);

  // Vérifier la persistance sur la commande.
  const { data: ord } = orderId ? await sb.from('restaurant_orders').select('delivery_fee, delivery_fee_paid_by').eq('id', orderId).maybeSingle() : { data: null };
  const ok3 = ord?.delivery_fee === expectedFee && ord?.delivery_fee_paid_by === 'client';
  log(`Commande en base : delivery_fee=${ord?.delivery_fee} paid_by=${ord?.delivery_fee_paid_by} → ${ok3 ? '✅' : '❌'}`);

  await anon.auth.signOut();
  // cleanup complet (owner + client + fixture)
  try { if (orderId) { await sb.from('deliveries').delete().eq('restaurant_order_id', orderId); await sb.from('restaurant_orders').delete().eq('id', orderId); } } catch {}
  try { await sb.from('restaurant_menu_items').delete().eq('id', itemId); } catch {}
  try { await sb.from('professional_services').delete().eq('id', svcId); } catch {}
  // NE PAS supprimer le BUYER (compte de test réel réutilisé) — on retire juste la fixture + l'owner jetable.
  try { await sb.from('profiles').delete().eq('id', owner.user.id); await sb.auth.admin.deleteUser(owner.user.id); } catch {}

  const pass = ok1 && ok2 && ok3;
  log(pass ? '\n🎉 SUCCÈS : le calcul des frais par DISTANCE fonctionne de bout en bout (endpoint réel).' : `\n⚠️  ÉCHEC — réponse: ${JSON.stringify(body)}`);
  process.exit(pass ? 0 : 2);
}

main().catch(async (e) => { console.error('💥', e); await cleanup(); process.exit(1); });
