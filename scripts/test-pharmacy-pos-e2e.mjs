// Test e2e — Caisse pharmacie hors ligne (create_pharmacy_pos_offline_order).
// Prérequis : migration 20260617150000 appliquée.
//   1) Vente comptoir → commande 'collected'/'paid' + stock décrémenté.
//   2) Idempotence : rejeu de la même clé → 'duplicate', stock NON re-décrémenté.
//   3) Autorisation : un autre utilisateur ne peut PAS encaisser sur cette caisse.
// La RPC vérifie auth.uid() = propriétaire → on se connecte en tant que propriétaire.
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const URL = process.env.SUPABASE_URL, KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const ANON = process.env.SUPABASE_ANON_KEY;
const sb = createClient(URL, KEY, { auth: { persistSession: false } });
const PHARMA_TYPE = 'b8f7e6d5-c4a3-4b21-9e0f-1a2b3c4d5e6f';
const log = (...a) => console.log(...a);
const ok = (c, m) => { log(`${c ? '✅' : '❌'} ${m}`); return c; };

let ownerId = null, strangerId = null, svcId = null, medId = null;
async function cleanup() {
  try { if (svcId) await sb.from('pharmacy_orders').delete().eq('pharmacy_id', svcId); } catch {}
  try { if (medId) await sb.from('pharmacy_medications').delete().eq('id', medId); } catch {}
  try { if (svcId) await sb.from('professional_services').delete().eq('id', svcId); } catch {}
  try { if (ownerId) await sb.auth.admin.deleteUser(ownerId); } catch {}
  try { if (strangerId) await sb.auth.admin.deleteUser(strangerId); } catch {}
}

async function signedClient(email) {
  const c = createClient(URL, ANON || KEY, { auth: { persistSession: false } });
  const { error } = await c.auth.signInWithPassword({ email, password: 'Test1234!' });
  if (error) throw new Error(`signin ${email}: ${error.message}`);
  return c;
}

async function main() {
  if (!ANON) { log('⚠️  SUPABASE_ANON_KEY absent — requis pour tester l\'autorisation auth.uid(). Abandon.'); process.exit(0); }
  const ts = Date.now();
  const { data: o } = await sb.auth.admin.createUser({ email: `e2e-pharma-owner-${ts}@t.io`, password: 'Test1234!', email_confirm: true });
  ownerId = o.user.id;
  const { data: s } = await sb.auth.admin.createUser({ email: `e2e-pharma-stranger-${ts}@t.io`, password: 'Test1234!', email_confirm: true });
  strangerId = s.user.id;

  const { data: svc } = await sb.from('professional_services').insert({ user_id: ownerId, service_type_id: PHARMA_TYPE, business_name: 'E2E PHARMA POS (temp)', status: 'active' }).select('id').single();
  svcId = svc.id;
  const { data: med } = await sb.from('pharmacy_medications').insert({ pharmacy_id: svcId, name: 'Vitamine C', price: 3000, stock: 10, requires_prescription: false }).select('id, stock').single();
  medId = med.id;

  const ownerClient = await signedClient(`e2e-pharma-owner-${ts}@t.io`);
  let pass = true;
  const idem = `PHARMA-OFF-${ts}`;
  const sale = { total: 6000, payment_method: 'cash', customer_name: 'Comptoir', items: [{ medication_id: medId, name: 'Vitamine C', price: 3000, quantity: 2, subtotal: 6000 }] };

  // (1) Vente comptoir.
  const r1 = await ownerClient.rpc('create_pharmacy_pos_offline_order', { p_service_id: svcId, p_idempotency_key: idem, p_sale: sale });
  if (r1.error) { log('❌ vente:', r1.error.message); await cleanup(); process.exit(1); }
  const { data: med1 } = await sb.from('pharmacy_medications').select('stock').eq('id', medId).single();
  pass &= ok(r1.data?.status === 'created' && med1.stock === 8, `(1) Vente créée (status=${r1.data?.status}) + stock 10→${med1.stock} (attendu 8)`);

  // (2) Idempotence.
  const r2 = await ownerClient.rpc('create_pharmacy_pos_offline_order', { p_service_id: svcId, p_idempotency_key: idem, p_sale: sale });
  const { data: med2 } = await sb.from('pharmacy_medications').select('stock').eq('id', medId).single();
  pass &= ok(r2.data?.status === 'duplicate' && med2.stock === 8, `(2) Rejeu = duplicate, stock inchangé (=${med2.stock}) → pas de double décrément`);

  // (3) Autorisation : un étranger ne peut pas encaisser.
  const strangerClient = await signedClient(`e2e-pharma-stranger-${ts}@t.io`);
  const r3 = await strangerClient.rpc('create_pharmacy_pos_offline_order', { p_service_id: svcId, p_idempotency_key: `PHARMA-OFF-${ts}-x`, p_sale: sale });
  pass &= ok(!!r3.error && /NON_AUTORISE/.test(r3.error.message), `(3) Étranger refusé (${r3.error?.message || 'AUTORISÉ — faille !'})`);

  await cleanup();
  log(pass ? '\n🎉 SUCCÈS : caisse pharmacie offline (atomique + idempotente + autorisée).' : '\n⚠️  ÉCHEC.');
  process.exit(pass ? 0 : 2);
}
main().catch(async (e) => { console.error('💥', e); await cleanup(); process.exit(1); });
