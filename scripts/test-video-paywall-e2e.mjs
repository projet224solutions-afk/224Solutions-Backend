// Test e2e du PAYWALL VIDÉO (trigger enforce_video_premium, migration 20260616240000).
// Fixture isolée : utilisateur jetable + service temporaire, puis cleanup complet.
//
//   1) NON-PREMIUM : insérer une PHOTO dans service_gallery_images → AUTORISÉ.
//   2) NON-PREMIUM : insérer une VIDÉO → REJETÉ (VIDEO_PREMIUM_REQUIS).
//   3) PREMIUM (abonnement actif sur plan can_upload_video) : insérer une VIDÉO → AUTORISÉ.
//   4) service_showcase : vidéo NON-PREMIUM rejetée également.
//
// Le trigger n'agit que pour les clients authentifiés (auth.uid()), donc on s'authentifie
// RÉELLEMENT en tant que propriétaire (createUser + signInWithPassword).
//
// Lancer depuis backend/ :  node scripts/test-video-paywall-e2e.mjs
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const URL = process.env.SUPABASE_URL;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const ANON_KEY = process.env.SUPABASE_ANON_KEY;
if (!URL || !SERVICE_KEY || !ANON_KEY) { console.error('❌ clés Supabase manquantes dans backend/.env'); process.exit(1); }

const sb = createClient(URL, SERVICE_KEY, { auth: { persistSession: false } });
const log = (...a) => console.log(...a);
const email = `e2e-video-${Date.now()}@test.224solutions.local`;
const password = `Test!${Math.random().toString(36).slice(2, 10)}Aa1`;
let testUserId = null, svcId = null, subId = null;

async function cleanup() {
  try { if (svcId) await sb.from('service_gallery_images').delete().eq('professional_service_id', svcId); } catch {}
  try { if (svcId) await sb.from('service_showcase').delete().eq('professional_service_id', svcId); } catch {}
  try { if (subId) await sb.from('service_subscriptions').delete().eq('id', subId); } catch {}
  try { if (svcId) await sb.from('professional_services').delete().eq('id', svcId); } catch {}
  try { if (testUserId) await sb.from('profiles').delete().eq('id', testUserId); } catch {}
  try { if (testUserId) await sb.auth.admin.deleteUser(testUserId); } catch {}
}

async function main() {
  // Trouver un type de service ayant un plan premium can_upload_video=true.
  const { data: premiumPlan } = await sb.from('service_plans')
    .select('id, service_type_id, monthly_price_gnf')
    .eq('name', 'premium').eq('is_active', true).eq('can_upload_video', true).limit(1).maybeSingle();
  if (!premiumPlan) { log('❌ Aucun plan premium can_upload_video=true trouvé.'); process.exit(1); }
  const serviceTypeId = premiumPlan.service_type_id;

  const { data: created, error: cErr } = await sb.auth.admin.createUser({ email, password, email_confirm: true });
  if (cErr) { log('❌ createUser:', cErr.message); process.exit(1); }
  testUserId = created.user.id;
  await sb.from('profiles').upsert({ id: testUserId, email, role: 'vendeur', full_name: 'E2E Video Owner' }, { onConflict: 'id' });

  const { data: svc, error: sErr } = await sb.from('professional_services').insert({
    user_id: testUserId, service_type_id: serviceTypeId, business_name: 'E2E VIDEO PAYWALL (temp)', status: 'active',
  }).select('id').single();
  if (sErr) { log('❌ création service:', sErr.message); await cleanup(); process.exit(1); }
  svcId = svc.id;
  log(`🎬 Fixture : service ${svcId} (type ${String(serviceTypeId).slice(0,8)}, premium=${premiumPlan.monthly_price_gnf} GNF) — owner sans abonnement`);

  const owner = createClient(URL, ANON_KEY, { auth: { persistSession: false } });
  const { error: signErr } = await owner.auth.signInWithPassword({ email, password });
  if (signErr) { log('❌ signIn:', signErr.message); await cleanup(); process.exit(1); }

  let pass = true;

  // (1) NON-PREMIUM : photo autorisée.
  const { error: e1 } = await owner.from('service_gallery_images').insert({
    professional_service_id: svcId, media_type: 'image', image_url: 'https://example.com/p.jpg', display_order: 0,
  });
  const ok1 = !e1;
  log(`(1) Photo (non-premium) : ${e1 ? '❌ REFUSÉE ' + e1.message : 'AUTORISÉE'} → ${ok1 ? '✅' : '❌'}`);
  pass &&= ok1;

  // (2) NON-PREMIUM : vidéo rejetée.
  const { error: e2 } = await owner.from('service_gallery_images').insert({
    professional_service_id: svcId, media_type: 'video', video_url: 'https://example.com/v.mp4', display_order: 1,
  });
  const ok2 = !!e2 && /VIDEO_PREMIUM_REQUIS/.test(e2.message);
  log(`(2) Vidéo (non-premium) : ${e2 ? 'REJETÉE (' + e2.message.slice(0,40) + ')' : '❌ AUTORISÉE (faille !)'} → ${ok2 ? '✅' : '❌'}`);
  pass &&= ok2;

  // (2b) service_showcase : vidéo non-premium rejetée aussi.
  const { error: e2b } = await owner.from('service_showcase').insert({
    professional_service_id: svcId, title: 'Test', image_url: 'https://example.com/i.jpg', video_url: 'https://example.com/v.mp4', price: 1000,
  });
  const ok2b = !!e2b && /VIDEO_PREMIUM_REQUIS/.test(e2b.message);
  log(`(2b) Vitrine vidéo (non-premium) : ${e2b ? 'REJETÉE' : '❌ AUTORISÉE (faille !)'} → ${ok2b ? '✅' : '❌'}`);
  pass &&= ok2b;

  // (3) Donner un abonnement Premium ACTIF, puis vidéo autorisée.
  const { data: sub, error: subErr } = await sb.from('service_subscriptions').insert({
    professional_service_id: svcId, plan_id: premiumPlan.id, status: 'active', user_id: testUserId,
    current_period_start: new Date().toISOString(),
    current_period_end: new Date(Date.now() + 30 * 864e5).toISOString(),
    price_paid_gnf: premiumPlan.monthly_price_gnf || 0,
  }).select('id').single();
  if (subErr) { log('⚠️  création abonnement premium impossible:', subErr.message, '→ test (3) sauté'); }
  else {
    subId = sub.id;
    const { error: e3 } = await owner.from('service_gallery_images').insert({
      professional_service_id: svcId, media_type: 'video', video_url: 'https://example.com/v2.mp4', display_order: 2,
    });
    const ok3 = !e3;
    log(`(3) Vidéo (premium actif) : ${e3 ? '❌ REFUSÉE ' + e3.message : 'AUTORISÉE'} → ${ok3 ? '✅' : '❌'}`);
    pass &&= ok3;
  }

  await owner.auth.signOut();
  await cleanup();
  log('\n🧹 Fixture nettoyée.');
  log(pass ? '\n🎉 SUCCÈS : paywall vidéo verrouillé en base (photo libre, vidéo réservée au Premium).'
           : '\n⚠️  ÉCHEC — voir ci-dessus.');
  process.exit(pass ? 0 : 2);
}

main().catch(async (e) => { console.error('💥', e); await cleanup(); process.exit(1); });
