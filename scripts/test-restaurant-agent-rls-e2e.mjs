// Test e2e RLS du système d'agents restaurant (migration 20260616300000).
// Vérifie : l'agent actif voit les données de SON restaurant ; un étranger ne voit rien ;
// les fonctions d'autorisation (is_service_owner_or_agent / service_agent_has_permission) sont correctes.
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const URL = process.env.SUPABASE_URL, SK = process.env.SUPABASE_SERVICE_ROLE_KEY, AK = process.env.SUPABASE_ANON_KEY;
const sb = createClient(URL, SK, { auth: { persistSession: false } });
const RESTAURANT_TYPE = '4aa11ff0-946e-4bc6-9c6a-af73e388868d';
const log = (...a) => console.log(...a);
const pw = `Test!${Math.random().toString(36).slice(2, 10)}Aa1`;
const ids = { owner: null, agent: null, stranger: null, svc: null, order: null };

async function mkUser(tag, role) {
  const email = `e2e-ragent-${tag}-${Date.now()}@test.224solutions.local`;
  const { data, error } = await sb.auth.admin.createUser({ email, password: pw, email_confirm: true });
  if (error) throw new Error(`createUser ${tag}: ${error.message}`);
  await sb.from('profiles').upsert({ id: data.user.id, email, role }, { onConflict: 'id' });
  return { id: data.user.id, email };
}
const signIn = async (email) => { const c = createClient(URL, AK, { auth: { persistSession: false } }); await c.auth.signInWithPassword({ email, password: pw }); return c; };
async function cleanup() {
  try { if (ids.svc) await sb.from('restaurant_orders').delete().eq('professional_service_id', ids.svc); } catch {}
  try { if (ids.svc) await sb.from('restaurant_agents').delete().eq('professional_service_id', ids.svc); } catch {}
  try { if (ids.svc) await sb.from('professional_services').delete().eq('id', ids.svc); } catch {}
  for (const k of ['owner', 'agent', 'stranger']) { try { if (ids[k]) { await sb.from('profiles').delete().eq('id', ids[k]); await sb.auth.admin.deleteUser(ids[k]); } } catch {} }
}

async function main() {
  const owner = await mkUser('owner', 'vendeur'); ids.owner = owner.id;
  const agent = await mkUser('agent', 'client'); ids.agent = agent.id;
  const stranger = await mkUser('stranger', 'client'); ids.stranger = stranger.id;

  const { data: svc } = await sb.from('professional_services').insert({ user_id: owner.id, service_type_id: RESTAURANT_TYPE, business_name: 'E2E RAGENT (temp)', status: 'active' }).select('id').single();
  ids.svc = svc.id;
  const { data: ord } = await sb.from('restaurant_orders').insert({ professional_service_id: ids.svc, status: 'pending', order_type: 'dine_in', total: 5000, items: [] }).select('id').single();
  ids.order = ord.id;
  // Agent actif avec permission manage_orders uniquement.
  await sb.from('restaurant_agents').insert({ professional_service_id: ids.svc, user_id: agent.id, name: 'Agent Test', permissions: { manage_orders: true, access_pos: false }, is_active: true });
  log(`Fixture : resto ${ids.svc}, 1 commande, agent (manage_orders=true, access_pos=false)`);

  let pass = true;
  const cAgent = await signIn(agent.email);
  const cStranger = await signIn(stranger.email);

  // (1) L'agent voit les commandes de son resto.
  const { data: aOrders } = await cAgent.from('restaurant_orders').select('id').eq('professional_service_id', ids.svc);
  const ok1 = (aOrders?.length || 0) === 1;
  log(`(1) Agent voit les commandes du resto : ${aOrders?.length || 0} (attendu 1) → ${ok1 ? '✅' : '❌'}`);
  pass &&= ok1;

  // (2) L'étranger ne voit rien.
  const { data: sOrders } = await cStranger.from('restaurant_orders').select('id').eq('professional_service_id', ids.svc);
  const ok2 = (sOrders?.length || 0) === 0;
  log(`(2) Étranger voit les commandes : ${sOrders?.length || 0} (attendu 0) → ${ok2 ? '✅' : '❌'}`);
  pass &&= ok2;

  // (3) L'agent peut écrire (accepter une commande) — RLS UPDATE.
  const { error: upErr } = await cAgent.from('restaurant_orders').update({ status: 'preparing' }).eq('id', ids.order);
  const { data: ordChk } = await sb.from('restaurant_orders').select('status').eq('id', ids.order).single();
  const ok3 = !upErr && ordChk?.status === 'preparing';
  log(`(3) Agent peut modifier une commande : ${upErr ? '❌ ' + upErr.message : 'status=' + ordChk?.status} → ${ok3 ? '✅' : '❌'}`);
  pass &&= ok3;

  // (4) Fonctions d'autorisation.
  const { data: isAgent } = await cAgent.rpc('is_service_owner_or_agent', { p_service_id: ids.svc });
  const { data: permOrders } = await cAgent.rpc('service_agent_has_permission', { p_service_id: ids.svc, p_permission: 'manage_orders' });
  const { data: permPos } = await cAgent.rpc('service_agent_has_permission', { p_service_id: ids.svc, p_permission: 'access_pos' });
  const ok4 = isAgent === true && permOrders === true && permPos === false;
  log(`(4) Autorisations : is_owner_or_agent=${isAgent} | manage_orders=${permOrders} | access_pos=${permPos} (attendu true/true/false) → ${ok4 ? '✅' : '❌'}`);
  pass &&= ok4;

  // (5) Étranger : aucune autorisation.
  const { data: strAuth } = await cStranger.rpc('is_service_owner_or_agent', { p_service_id: ids.svc });
  const ok5 = strAuth === false;
  log(`(5) Étranger is_owner_or_agent=${strAuth} (attendu false) → ${ok5 ? '✅' : '❌'}`);
  pass &&= ok5;

  await cAgent.auth.signOut(); await cStranger.auth.signOut();
  await cleanup();
  log(pass ? '\n🎉 SUCCÈS : RLS agents restaurant OK (accès scopé, écriture, permissions par module, étranger bloqué).' : '\n⚠️  ÉCHEC.');
  process.exit(pass ? 0 : 2);
}
main().catch(async (e) => { console.error('💥', e); await cleanup(); process.exit(1); });
