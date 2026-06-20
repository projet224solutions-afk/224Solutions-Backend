/**
 * E2E — Confidentialité des photos d'ordonnances (bucket privé `prescriptions`).
 * Prérequis : migration 20260617140000 appliquée.
 *
 * Prouve : (1) le bucket existe et est PRIVÉ ; (2) l'URL publique d'un fichier uploadé
 * est REFUSÉE (pas de fuite) ; (3) une URL signée backend donne bien accès (200).
 *
 * Lancer : node scripts/test-prescription-privacy-e2e.mjs
 */
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!url || !key) { console.error('SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY requis'); process.exit(1); }
const admin = createClient(url, key, { auth: { persistSession: false } });

const CLIENT = '876d385a-a14f-4891-954b-80895ba187b8';
const BUCKET = 'prescriptions';
const path = `${CLIENT}/e2e-${Date.now()}.txt`;
const ok = (c, m) => console.log(`${c ? '✅' : '❌'} ${m}`);

async function run() {
  // (1) Bucket privé ?
  const { data: bucket } = await admin.storage.getBucket(BUCKET);
  ok(bucket && bucket.public === false, `(1) bucket "${BUCKET}" existe et privé (public=${bucket?.public})`);

  // Upload via service_role.
  const { error: upErr } = await admin.storage.from(BUCKET).upload(path, new Blob(['ORDONNANCE-SECRETE']), { contentType: 'text/plain', upsert: true });
  if (upErr) { console.error('upload échoué:', upErr.message); process.exit(1); }

  // (2) URL publique → doit être REFUSÉE.
  const { data: pub } = admin.storage.from(BUCKET).getPublicUrl(path);
  let publicStatus = 0;
  try { publicStatus = (await fetch(pub.publicUrl)).status; } catch { publicStatus = -1; }
  ok(publicStatus !== 200, `(2) URL publique refusée (HTTP ${publicStatus}, attendu ≠ 200)`);

  // (3) URL signée → doit DONNER accès.
  const { data: signed, error: sErr } = await admin.storage.from(BUCKET).createSignedUrl(path, 300);
  let signedStatus = 0; let body = '';
  if (!sErr && signed?.signedUrl) {
    const r = await fetch(signed.signedUrl); signedStatus = r.status; body = await r.text();
  }
  ok(signedStatus === 200 && body.includes('ORDONNANCE-SECRETE'), `(3) URL signée accessible (HTTP ${signedStatus})`);

  await admin.storage.from(BUCKET).remove([path]);
  console.log('\n🎉 Test confidentialité ordonnances terminé (nettoyé).');
}
run().catch((e) => { console.error(e); process.exit(1); });
