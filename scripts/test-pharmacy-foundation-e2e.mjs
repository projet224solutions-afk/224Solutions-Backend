// Test e2e Phase 1 pharmacie : service_type + 4 plans créés, et isolation RLS des ordonnances
// (client voit les siennes, pharmacien celles de son service, étranger rien).
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const URL = process.env.SUPABASE_URL, SK = process.env.SUPABASE_SERVICE_ROLE_KEY, AK = process.env.SUPABASE_ANON_KEY;
const sb = createClient(URL, SK, { auth: { persistSession: false } });
const PHARMA_TYPE = 'b8f7e6d5-c4a3-4b21-9e0f-1a2b3c4d5e6f';
const log = (...a) => console.log(...a);
const pw = `Test!${Math.random().toString(36).slice(2, 10)}Aa1`;
const ids = { owner: null, client: null, stranger: null, svc: null, presc: null };

async function mkUser(tag, role) {
  const email = `e2e-pharm-${tag}-${Date.now()}@test.224solutions.local`;
  const { data, error } = await sb.auth.admin.createUser({ email, password: pw, email_confirm: true });
  if (error) throw new Error(`createUser ${tag}: ${error.message}`);
  await sb.from('profiles').upsert({ id: data.user.id, email, role }, { onConflict: 'id' });
  return { id: data.user.id, email };
}
const signIn = async (email) => { const c = createClient(URL, AK, { auth: { persistSession: false } }); await c.auth.signInWithPassword({ email, password: pw }); return c; };
async function cleanup() {
  try { if (ids.svc) await sb.from('prescriptions').delete().eq('pharmacy_id', ids.svc); } catch {}
  try { if (ids.svc) await sb.from('professional_services').delete().eq('id', ids.svc); } catch {}
  for (const k of ['owner', 'client', 'stranger']) { try { if (ids[k]) { await sb.from('profiles').delete().eq('id', ids[k]); await sb.auth.admin.deleteUser(ids[k]); } } catch {} }
}

async function main() {
  let pass = true;

  // (0) service_type + plans présents.
  const { data: st } = await sb.from('service_types').select('id, code, name').eq('code', 'pharmacie').maybeSingle();
  const { data: plans } = await sb.from('service_plans').select('name, monthly_price_gnf').eq('service_type_id', PHARMA_TYPE).order('display_order');
  const ok0 = st?.id === PHARMA_TYPE && (plans?.length || 0) === 4;
  log(`(0) service_type pharmacie + plans : type=${st?.code} | plans=${(plans || []).map(p => p.name + ':' + p.monthly_price_gnf).join(', ')} → ${ok0 ? '✅' : '❌'}`);
  pass &&= ok0;

  // Fixture : pharmacien + service pharmacie + client + étranger + 1 ordonnance.
  const owner = await mkUser('owner', 'prestataire'); ids.owner = owner.id;
  const client = await mkUser('client', 'client'); ids.client = client.id;
  const stranger = await mkUser('stranger', 'client'); ids.stranger = stranger.id;
  const { data: svc } = await sb.from('professional_services').insert({ user_id: owner.id, service_type_id: PHARMA_TYPE, business_name: 'E2E PHARMACIE (temp)', status: 'active' }).select('id').single();
  ids.svc = svc.id;
  const { data: presc } = await sb.from('prescriptions').insert({ client_id: client.id, pharmacy_id: ids.svc, photos: ['https://x/p.jpg'], status: 'pending' }).select('id').single();
  ids.presc = presc.id;
  log(`Fixture : pharmacie ${ids.svc}, 1 ordonnance (client ${client.id.slice(0, 8)})`);

  const cClient = await signIn(client.email);
  const cStranger = await signIn(stranger.email);
  const cOwner = await signIn(owner.email);

  // (1) Le client voit SON ordonnance.
  const { data: c1 } = await cClient.from('prescriptions').select('id').eq('pharmacy_id', ids.svc);
  const ok1 = (c1?.length || 0) === 1;
  log(`(1) Client voit son ordonnance : ${c1?.length || 0} (attendu 1) → ${ok1 ? '✅' : '❌'}`);
  pass &&= ok1;

  // (2) L'étranger ne voit rien.
  const { data: c2 } = await cStranger.from('prescriptions').select('id').eq('pharmacy_id', ids.svc);
  const ok2 = (c2?.length || 0) === 0;
  log(`(2) Étranger voit : ${c2?.length || 0} (attendu 0) → ${ok2 ? '✅' : '❌'}`);
  pass &&= ok2;

  // (3) Le pharmacien (propriétaire) voit l'ordonnance reçue + peut la valider (UPDATE).
  const { data: c3 } = await cOwner.from('prescriptions').select('id').eq('pharmacy_id', ids.svc);
  const { error: e3 } = await cOwner.from('prescriptions').update({ status: 'reviewing' }).eq('id', ids.presc);
  const ok3 = (c3?.length || 0) === 1 && !e3;
  log(`(3) Pharmacien voit + modifie : voit=${c3?.length || 0} | update=${e3 ? '❌ ' + e3.message : 'OK'} → ${ok3 ? '✅' : '❌'}`);
  pass &&= ok3;

  // (4) Catalogue médicaments lisible publiquement (sans connexion = anon).
  const anon = createClient(URL, AK, { auth: { persistSession: false } });
  const { error: e4 } = await anon.from('pharmacy_medications').select('id').limit(1);
  const ok4 = !e4; // lecture autorisée (table vide OK)
  log(`(4) Catalogue lisible (anon) : ${e4 ? '❌ ' + e4.message : 'OK'} → ${ok4 ? '✅' : '❌'}`);
  pass &&= ok4;

  await cClient.auth.signOut(); await cStranger.auth.signOut(); await cOwner.auth.signOut();
  await cleanup();
  log(pass ? '\n🎉 SUCCÈS : fondation pharmacie OK (service_type + 4 plans + RLS scopé : client/pharmacien isolés, étranger bloqué).' : '\n⚠️  ÉCHEC.');
  process.exit(pass ? 0 : 2);
}
main().catch(async (e) => { console.error('💥', e); await cleanup(); process.exit(1); });
