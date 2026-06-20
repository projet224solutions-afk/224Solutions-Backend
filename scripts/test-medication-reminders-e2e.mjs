/**
 * E2E — Rappels de prise de médicaments (Phase 6).
 * Prérequis : migrations 20260617130000 appliquées (start_date + medication_reminder_sent).
 *
 * Vérifie : (1) un rappel dont l'heure = maintenant génère UNE notification + une ligne au
 * journal ; (2) un 2e passage ne crée AUCUN doublon (idempotence) ; (3) un rappel expiré
 * (duration_days dépassé) n'est PAS notifié. Le scheduler réel est importé et exécuté.
 *
 * Lancer : node --experimental-strip-types scripts/test-medication-reminders-e2e.mjs
 *   (ou npx tsx scripts/test-medication-reminders-e2e.mjs)
 */
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!url || !key) { console.error('SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY requis'); process.exit(1); }
const admin = createClient(url, key, { auth: { persistSession: false } });

const CLIENT = '876d385a-a14f-4891-954b-80895ba187b8'; // client de test connu
const todayStr = new Date().toISOString().slice(0, 10);
const now = new Date();
const hhmm = `${String(now.getUTCHours()).padStart(2, '0')}:${String(now.getUTCMinutes()).padStart(2, '0')}`;
const slotTime = `${hhmm}:00`;

const ok = (c, m) => console.log(`${c ? '✅' : '❌'} ${m}`);
let createdIds = [];

async function countNotifs() {
  const { count } = await admin.from('notifications')
    .select('id', { count: 'exact', head: true })
    .eq('user_id', CLIENT).eq('type', 'medication_reminder');
  return count || 0;
}

async function run() {
  // Rappel « dû » (heure = maintenant), + rappel expiré (commencé il y a 30 j, durée 7 j).
  const past = new Date(Date.now() - 30 * 86400_000).toISOString().slice(0, 10);
  const { data: due, error: e1 } = await admin.from('medication_reminders').insert({
    client_id: CLIENT, medication_name: 'E2E-DueMed', times: [slotTime], duration_days: null, start_date: todayStr, active: true,
  }).select('id').single();
  if (e1) { console.error('insert due:', e1.message); process.exit(1); }
  const { data: exp } = await admin.from('medication_reminders').insert({
    client_id: CLIENT, medication_name: 'E2E-ExpiredMed', times: [slotTime], duration_days: 7, start_date: past, active: true,
  }).select('id').single();
  createdIds = [due.id, exp?.id].filter(Boolean);

  const before = await countNotifs();
  const { medicationReminderScheduler } = await import('../src/services/medicationReminder.service.ts');

  const r1 = await medicationReminderScheduler.runOnce('test');
  const after1 = await countNotifs();
  ok(after1 - before === 1, `(1) 1 notification créée pour le rappel dû (Δ=${after1 - before}, scanned=${r1.scanned}, sent=${r1.sent})`);

  const { data: log } = await admin.from('medication_reminder_sent').select('*').eq('reminder_id', due.id).eq('slot_date', todayStr);
  ok((log || []).length === 1, `(1b) 1 ligne au journal anti-doublon (=${(log || []).length})`);

  const r2 = await medicationReminderScheduler.runOnce('test-replay');
  const after2 = await countNotifs();
  ok(after2 === after1 && r2.sent === 0, `(2) 2e passage = AUCUN doublon (notifs=${after2}, sent=${r2.sent})`);

  const { data: expLog } = await admin.from('medication_reminder_sent').select('*').eq('reminder_id', exp.id);
  ok((expLog || []).length === 0, `(3) rappel expiré NON notifié (lignes=${(expLog || []).length})`);

  // Nettoyage
  await admin.from('medication_reminders').delete().in('id', createdIds);
  await admin.from('notifications').delete().eq('user_id', CLIENT).eq('type', 'medication_reminder').gte('created_at', new Date(Date.now() - 600_000).toISOString());
  console.log('\n🎉 Test rappels médicaments terminé (nettoyé).');
}
run().catch((e) => { console.error(e); process.exit(1); });
