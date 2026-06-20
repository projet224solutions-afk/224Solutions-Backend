// Test e2e de la gestion des agents restaurant via l'endpoint /api/v2/restaurant/agents.
// Vérifie : création (compte auth + ligne), liste, mise à jour permissions, suppression,
// et sécurité (un non-propriétaire ne peut pas créer d'agent). Prérequis : backend lancé (3001).
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const API = process.env.TEST_API_URL || 'http://localhost:3001';
const URL = process.env.SUPABASE_URL, SK = process.env.SUPABASE_SERVICE_ROLE_KEY, AK = process.env.SUPABASE_ANON_KEY;
const sb = createClient(URL, SK, { auth: { persistSession: false } });
const RESTAURANT_TYPE = '4aa11ff0-946e-4bc6-9c6a-af73e388868d';
const log = (...a) => console.log(...a);
const pw = `Test!${Math.random().toString(36).slice(2, 10)}Aa1`;
let ownerId = null, strangerId = null, svcId = null, agentId = null, agentUserId = null;
const agentEmail = `e2e-ragent-${Date.now()}@test.224solutions.local`;

async function mkUser(tag) {
  const email = `e2e-${tag}-${Date.now()}@test.224solutions.local`;
  const { data } = await sb.auth.admin.createUser({ email, password: pw, email_confirm: true });
  await sb.from('profiles').upsert({ id: data.user.id, email, role: 'vendeur' }, { onConflict: 'id' });
  return { id: data.user.id, email };
}
const signIn = async (email) => { const c = createClient(URL, AK, { auth: { persistSession: false } }); const { data } = await c.auth.signInWithPassword({ email, password: pw }); return data.session.access_token; };
const api = (token, path, method, body) => fetch(`${API}${path}`, { method, headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` }, body: body ? JSON.stringify(body) : undefined }).then(r => r.json());

async function cleanup() {
  try { if (svcId) await sb.from('restaurant_agents').delete().eq('professional_service_id', svcId); } catch {}
  try { if (svcId) await sb.from('professional_services').delete().eq('id', svcId); } catch {}
  try { if (agentUserId) { await sb.from('profiles').delete().eq('id', agentUserId); await sb.auth.admin.deleteUser(agentUserId); } } catch {}
  for (const id of [ownerId, strangerId]) { try { if (id) { await sb.from('profiles').delete().eq('id', id); await sb.auth.admin.deleteUser(id); } } catch {} }
}

async function main() {
  try { const h = await fetch(`${API}/healthz.json`); if (!h.ok) throw 0; } catch { log(`❌ Backend injoignable sur ${API}`); process.exit(1); }
  const owner = await mkUser('owner'); ownerId = owner.id;
  const stranger = await mkUser('stranger'); strangerId = stranger.id;
  const { data: svc } = await sb.from('professional_services').insert({ user_id: owner.id, service_type_id: RESTAURANT_TYPE, business_name: 'E2E AGENTS (temp)', status: 'active' }).select('id').single();
  svcId = svc.id;
  const ownerTok = await signIn(owner.email);
  const strangerTok = await signIn(stranger.email);
  let pass = true;

  // (1) Création d'un agent avec permissions manage_orders + access_pos.
  const created = await api(ownerTok, '/api/v2/restaurant/agents', 'POST', {
    professional_service_id: svcId, name: 'Agent Resto', email: agentEmail, phone: '+224000', password: 'AgentPass123',
    permissions: { manage_orders: true, access_pos: true, manage_menu: false },
  });
  agentId = created?.data?.id;
  const { data: row } = agentId ? await sb.from('restaurant_agents').select('user_id, permissions, is_active').eq('id', agentId).maybeSingle() : { data: null };
  agentUserId = row?.user_id;
  const ok1 = created.success === true && !!agentId && row?.permissions?.manage_orders === true && row?.permissions?.manage_menu === false && !!agentUserId;
  log(`(1) Création agent : ${created.success ? 'OK id=' + (agentId || '').slice(0, 8) : '❌ ' + created.error} | compte auth=${agentUserId ? 'créé' : 'absent'} → ${ok1 ? '✅' : '❌'}`);
  pass &&= ok1;

  // (2) Liste.
  const list = await api(ownerTok, `/api/v2/restaurant/agents?service_id=${svcId}`, 'GET');
  const ok2 = list.success && (list.data || []).some(a => a.id === agentId);
  log(`(2) Liste agents : ${(list.data || []).length} → ${ok2 ? '✅' : '❌'}`);
  pass &&= ok2;

  // (3) Mise à jour permissions (ajoute manage_menu, retire access_pos).
  const upd = await api(ownerTok, `/api/v2/restaurant/agents/${agentId}`, 'PATCH', { permissions: { manage_orders: true, manage_menu: true, access_pos: false } });
  const { data: row2 } = await sb.from('restaurant_agents').select('permissions').eq('id', agentId).maybeSingle();
  const ok3 = upd.success && row2?.permissions?.manage_menu === true && row2?.permissions?.access_pos === false;
  log(`(3) Update permissions : manage_menu=${row2?.permissions?.manage_menu} access_pos=${row2?.permissions?.access_pos} → ${ok3 ? '✅' : '❌'}`);
  pass &&= ok3;

  // (4) Sécurité : un étranger (non propriétaire) ne peut PAS créer d'agent sur ce service.
  const hack = await api(strangerTok, '/api/v2/restaurant/agents', 'POST', {
    professional_service_id: svcId, name: 'Pirate', email: `pirate-${Date.now()}@x.cd`, password: 'Pirate12345',
  });
  const ok4 = hack.success === false && /autoris/i.test(hack.error || '');
  log(`(4) Étranger crée agent : ${hack.success ? '❌ AUTORISÉ (faille)' : 'REFUSÉ (' + hack.error + ')'} → ${ok4 ? '✅' : '❌'}`);
  pass &&= ok4;

  // (5) Suppression (agent + compte auth).
  const del = await api(ownerTok, `/api/v2/restaurant/agents/${agentId}`, 'DELETE');
  const { count } = await sb.from('restaurant_agents').select('id', { count: 'exact', head: true }).eq('id', agentId);
  const { data: authStill } = await sb.auth.admin.getUserById(agentUserId);
  const ok5 = del.success && count === 0 && !authStill?.user;
  log(`(5) Suppression : ligne=${count} compte=${authStill?.user ? 'reste ❌' : 'supprimé'} → ${ok5 ? '✅' : '❌'}`);
  pass &&= ok5;
  if (ok5) agentUserId = null; // déjà supprimé

  await cleanup();
  log(pass ? '\n🎉 SUCCÈS : gestion agents restaurant (création/liste/permissions/sécurité/suppression) OK.' : '\n⚠️  ÉCHEC.');
  process.exit(pass ? 0 : 2);
}
main().catch(async (e) => { console.error('💥', e); await cleanup(); process.exit(1); });
