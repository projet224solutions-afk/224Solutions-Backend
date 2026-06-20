// Test e2e des AVIS RESTAURANT (RPC submit_restaurant_review, migration 20260616250000).
// Fixture isolée : resto + 2 clients jetables (A a commandé, B non), puis cleanup.
//
//   1) Client A (commande livrée) note → succès, avis is_verified=true, note agrégée mise à jour.
//   2) Client A re-note (upsert) → TOUJOURS 1 seul avis, note actualisée (anti multi-vote).
//   3) Client B (aucune commande) note → REJETÉ (AUCUNE_COMMANDE).
//
// Lancer depuis backend/ :  node scripts/test-restaurant-review-e2e.mjs
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const URL = process.env.SUPABASE_URL, SK = process.env.SUPABASE_SERVICE_ROLE_KEY, AK = process.env.SUPABASE_ANON_KEY;
if (!URL || !SK || !AK) { console.error('❌ clés Supabase manquantes'); process.exit(1); }
const sb = createClient(URL, SK, { auth: { persistSession: false } });
const RESTAURANT_TYPE = '4aa11ff0-946e-4bc6-9c6a-af73e388868d';
const log = (...a) => console.log(...a);
const pw = `Test!${Math.random().toString(36).slice(2, 10)}Aa1`;
const ids = { owner: null, a: null, b: null, svc: null };

async function mkUser(tag) {
  const email = `e2e-review-${tag}-${Date.now()}@test.224solutions.local`;
  const { data, error } = await sb.auth.admin.createUser({ email, password: pw, email_confirm: true });
  if (error) throw new Error(`createUser ${tag}: ${error.message}`);
  await sb.from('profiles').upsert({ id: data.user.id, email, role: 'client' }, { onConflict: 'id' });
  return { id: data.user.id, email };
}
async function signIn(email) {
  const c = createClient(URL, AK, { auth: { persistSession: false } });
  const { error } = await c.auth.signInWithPassword({ email, password: pw });
  if (error) throw new Error('signIn: ' + error.message);
  return c;
}
async function cleanup() {
  try { if (ids.svc) await sb.from('service_reviews').delete().eq('professional_service_id', ids.svc); } catch {}
  try { if (ids.svc) await sb.from('restaurant_orders').delete().eq('professional_service_id', ids.svc); } catch {}
  try { if (ids.svc) await sb.from('professional_services').delete().eq('id', ids.svc); } catch {}
  for (const k of ['owner', 'a', 'b']) {
    try { if (ids[k]) await sb.from('profiles').delete().eq('id', ids[k]); } catch {}
    try { if (ids[k]) await sb.auth.admin.deleteUser(ids[k]); } catch {}
  }
}

async function main() {
  const owner = await mkUser('owner'); ids.owner = owner.id;
  const a = await mkUser('a'); ids.a = a.id;
  const b = await mkUser('b'); ids.b = b.id;

  const { data: svc, error: sErr } = await sb.from('professional_services').insert({
    user_id: owner.id, service_type_id: RESTAURANT_TYPE, business_name: 'E2E REVIEW (temp)', status: 'active',
  }).select('id').single();
  if (sErr) { log('❌ service:', sErr.message); await cleanup(); process.exit(1); }
  ids.svc = svc.id;

  // Client A a une commande livrée sur ce resto.
  await sb.from('restaurant_orders').insert({
    professional_service_id: ids.svc, customer_user_id: ids.a, status: 'completed',
    source: 'online', order_type: 'delivery', total: 5000, items: [],
  });
  log(`🍽️  Fixture : resto ${ids.svc} | client A a commandé, client B non`);

  let pass = true;
  const clientA = await signIn(a.email);
  const clientB = await signIn(b.email);

  // (1) A note → succès + agrégation.
  const { error: e1 } = await clientA.rpc('submit_restaurant_review', { p_service_id: ids.svc, p_rating: 5, p_comment: 'Excellent' });
  const { count: c1 } = await sb.from('service_reviews').select('id', { count: 'exact', head: true }).eq('professional_service_id', ids.svc);
  const { data: rev1 } = await sb.from('service_reviews').select('rating, is_verified').eq('professional_service_id', ids.svc).maybeSingle();
  const { data: svc1 } = await sb.from('professional_services').select('rating, total_reviews').eq('id', ids.svc).single();
  const ok1 = !e1 && c1 === 1 && rev1?.is_verified === true && Number(svc1?.rating) === 5 && Number(svc1?.total_reviews) === 1;
  log(`(1) A note 5★ : ${e1 ? '❌ ' + e1.message : `avis=${c1}, verified=${rev1?.is_verified}, agrégat=${svc1?.rating}/5 (${svc1?.total_reviews})`} → ${ok1 ? '✅' : '❌'}`);
  pass &&= ok1;

  // (2) A re-note (upsert) → toujours 1 avis, note actualisée.
  const { error: e2 } = await clientA.rpc('submit_restaurant_review', { p_service_id: ids.svc, p_rating: 3, p_comment: 'Mise à jour' });
  const { count: c2 } = await sb.from('service_reviews').select('id', { count: 'exact', head: true }).eq('professional_service_id', ids.svc);
  const { data: svc2 } = await sb.from('professional_services').select('rating, total_reviews').eq('id', ids.svc).single();
  const ok2 = !e2 && c2 === 1 && Number(svc2?.rating) === 3 && Number(svc2?.total_reviews) === 1;
  log(`(2) A re-note 3★ (upsert) : ${e2 ? '❌ ' + e2.message : `avis=${c2} (attendu 1), agrégat=${svc2?.rating}/5`} → ${ok2 ? '✅' : '❌'}`);
  pass &&= ok2;

  // (3) B sans commande → rejeté.
  const { error: e3 } = await clientB.rpc('submit_restaurant_review', { p_service_id: ids.svc, p_rating: 5, p_comment: 'Faux avis' });
  const ok3 = !!e3 && /AUCUNE_COMMANDE/.test(e3.message);
  log(`(3) B sans commande : ${e3 ? 'REJETÉ (' + e3.message.slice(0, 30) + ')' : '❌ AUTORISÉ (faille !)'} → ${ok3 ? '✅' : '❌'}`);
  pass &&= ok3;

  await clientA.auth.signOut(); await clientB.auth.signOut();
  await cleanup();
  log('\n🧹 Fixture nettoyée.');
  log(pass ? '\n🎉 SUCCÈS : avis vérifié + anti multi-vote + agrégation OK.' : '\n⚠️  ÉCHEC — voir ci-dessus.');
  process.exit(pass ? 0 : 2);
}

main().catch(async (e) => { console.error('💥', e); await cleanup(); process.exit(1); });
