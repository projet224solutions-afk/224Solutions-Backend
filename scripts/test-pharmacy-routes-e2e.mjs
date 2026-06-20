// Test e2e des endpoints /api/v2/pharmacy (flux complet). Prérequis : backend lancé (3001).
//   client envoie ordonnance → pharmacien valide (devis) → client paie → pharmacien prépare.
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const API = 'http://localhost:3001';
const URL = process.env.SUPABASE_URL, SK = process.env.SUPABASE_SERVICE_ROLE_KEY, AK = process.env.SUPABASE_ANON_KEY;
const sb = createClient(URL, SK, { auth: { persistSession: false } });
const PHARMA_TYPE = 'b8f7e6d5-c4a3-4b21-9e0f-1a2b3c4d5e6f';
const CLIENT = '876d385a-a14f-4891-954b-80895ba187b8'; // wallet financé
const pw = `Test!${Math.random().toString(36).slice(2, 10)}Aa1`;
const log = (...a) => console.log(...a);
const api = (tok, path, method, body) => fetch(`${API}${path}`, { method, headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${tok}` }, body: body ? JSON.stringify(body) : undefined }).then(r => r.json());
let ownerId = null, svcId = null, prescId = null;

async function signInId(userId) { // pose un mdp temporaire + signIn → token
  const { data: u } = await sb.auth.admin.getUserById(userId);
  await sb.auth.admin.updateUserById(userId, { password: pw });
  const c = createClient(URL, AK, { auth: { persistSession: false } });
  const { data } = await c.auth.signInWithPassword({ email: u.user.email, password: pw });
  return data.session.access_token;
}
async function cleanup() {
  try { if (svcId) await sb.from('pharmacy_orders').delete().eq('pharmacy_id', svcId); } catch {}
  try { if (svcId) await sb.from('prescriptions').delete().eq('pharmacy_id', svcId); } catch {}
  try { if (svcId) await sb.from('professional_services').delete().eq('id', svcId); } catch {}
  try { if (ownerId) { await sb.from('profiles').delete().eq('id', ownerId); await sb.auth.admin.deleteUser(ownerId); } } catch {}
}

async function main() {
  try { const h = await fetch(`${API}/healthz.json`); if (!h.ok) throw 0; } catch { log('❌ backend injoignable'); process.exit(1); }

  // Pharmacien jetable + wallet (garde créditable) + service pharmacie.
  const email = `e2e-pharmown-${Date.now()}@test.224solutions.local`;
  const { data: o } = await sb.auth.admin.createUser({ email, password: pw, email_confirm: true });
  ownerId = o.user.id;
  await sb.from('profiles').upsert({ id: ownerId, email, role: 'prestataire' }, { onConflict: 'id' });
  await sb.rpc('credit_user_wallet_safe', { p_user_id: ownerId, p_amount: 100, p_currency: 'GNF' }).then(() => {}, () => {});
  const { data: svc } = await sb.from('professional_services').insert({ user_id: ownerId, service_type_id: PHARMA_TYPE, business_name: 'E2E PHARMA ROUTES (temp)', status: 'active' }).select('id').single();
  svcId = svc.id;

  const ownerTok = await signInId(ownerId);
  const clientTok = await signInId(CLIENT);
  let pass = true;

  // (1) Client envoie une ordonnance.
  const sent = await api(clientTok, '/api/v2/pharmacy/prescriptions', 'POST', { pharmacy_id: svcId, photos: ['https://x/ordo.jpg'], delivery_type: 'pickup' });
  prescId = sent?.data?.id;
  const ok1 = sent.success && !!prescId;
  log(`(1) Client envoie ordonnance : ${sent.success ? 'OK' : '❌ ' + sent.error} → ${ok1 ? '✅' : '❌'}`);
  pass &&= ok1;

  // (2) Pharmacien voit la file.
  const list = await api(ownerTok, `/api/v2/pharmacy/prescriptions?service_id=${svcId}`, 'GET');
  const ok2 = list.success && (list.data || []).some(p => p.id === prescId);
  log(`(2) Pharmacien voit la file : ${(list.data || []).length} ordonnance(s) → ${ok2 ? '✅' : '❌'}`);
  pass &&= ok2;

  // (3) Pharmacien valide (devis 2 médicaments).
  const meds = [{ name: 'Paracétamol', dosage: '500mg', quantity: 2, price: 1500, available: true }, { name: 'Amoxicilline', dosage: '1g', quantity: 1, price: 2000, available: true }];
  const val = await api(ownerTok, `/api/v2/pharmacy/prescriptions/${prescId}/validate`, 'POST', { medications: meds, notes: 'OK' });
  const ok3 = val.success && val.total === 5000; // 1500*2 + 2000
  log(`(3) Pharmacien valide (devis) : total=${val.total} (attendu 5000) → ${ok3 ? '✅' : '❌'}`);
  pass &&= ok3;

  // (4) Sécurité : un autre user ne peut pas valider.
  const hack = await api(clientTok, `/api/v2/pharmacy/prescriptions/${prescId}/validate`, 'POST', { medications: meds });
  const ok4 = hack.success === false && /réservée/i.test(hack.error || '');
  log(`(4) Sécurité (client tente de valider) : ${hack.success ? '❌ AUTORISÉ' : 'REFUSÉ'} → ${ok4 ? '✅' : '❌'}`);
  pass &&= ok4;

  // (5) Client paie le devis.
  const cBal0 = Number((await sb.from('wallets').select('balance').eq('user_id', CLIENT).maybeSingle()).data?.balance ?? 0);
  const paid = await api(clientTok, '/api/v2/pharmacy/order', 'POST', { prescription_id: prescId });
  const cBal1 = Number((await sb.from('wallets').select('balance').eq('user_id', CLIENT).maybeSingle()).data?.balance ?? 0);
  const ok5 = paid.success && !!paid.order_id && (cBal0 - cBal1) === 5000;
  log(`(5) Client paie : ${paid.success ? 'OK order=' + String(paid.order_id).slice(0, 8) : '❌ ' + paid.error} | Δclient=${cBal1 - cBal0} (attendu -5000) → ${ok5 ? '✅' : '❌'}`);
  pass &&= ok5;

  // (6) Pharmacien voit la commande à préparer + la fait avancer.
  const orders = await api(ownerTok, `/api/v2/pharmacy/orders?service_id=${svcId}`, 'GET');
  const oid = orders?.data?.[0]?.id;
  const adv = oid ? await api(ownerTok, `/api/v2/pharmacy/orders/${oid}/status`, 'POST', { status: 'ready' }) : { success: false };
  const ok6 = orders.success && !!oid && adv.success;
  log(`(6) Pharmacien : commande à préparer (${(orders.data || []).length}) + passage 'ready' → ${ok6 ? '✅' : '❌'}`);
  pass &&= ok6;

  await cleanup();
  log(pass ? '\n🎉 SUCCÈS : flux backend pharmacie complet (envoi → file → validation → sécurité → paiement → préparation).' : '\n⚠️  ÉCHEC.');
  process.exit(pass ? 0 : 2);
}
main().catch(async (e) => { console.error('💥', e); await cleanup(); process.exit(1); });
