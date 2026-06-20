// Test e2e — Suppression complète d'utilisateur (jusqu'à la base).
// Crée un utilisateur jetable + profil + wallet, appelle la logique partagée,
// puis vérifie que TOUT est supprimé : profiles, wallets, et le compte auth.users.
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const sb = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const log = (...a) => console.log(...a);
const ok = (c, m) => { log(`${c ? '✅' : '❌'} ${m}`); return c; };

async function main() {
  const ts = Date.now();
  const { data: created, error: cErr } = await sb.auth.admin.createUser({ email: `e2e-del-${ts}@t.io`, password: 'Test1234!', email_confirm: true });
  if (cErr) { log('❌ createUser:', cErr.message); process.exit(1); }
  const userId = created.user.id;

  // Données liées (profil + wallet) — ce sont elles qui bloquent une suppression auth « naïve ».
  await sb.from('profiles').upsert({ id: userId, email: `e2e-del-${ts}@t.io`, role: 'client', first_name: 'E2E', last_name: 'Delete' });
  await sb.from('wallets').insert({ user_id: userId, balance: 0, currency: 'GNF' });
  // Reproduit le bug #1 : transaction où le user est receiver (FK receiver_user_id).
  await sb.from('wallet_transactions').insert({
    transaction_id: `E2E-DEL-${ts}`, sender_user_id: null, receiver_user_id: userId,
    amount: 100, net_amount: 100, currency: 'GNF', transaction_type: 'payment', status: 'completed', description: 'e2e del',
  });

  // Reproduit le bug #2 : commande ACHETEUR avec escrow (escrow_transactions.order_id bloquait orders→customers→profiles).
  let { data: cust } = await sb.from('customers').select('id').eq('user_id', userId).maybeSingle();
  if (!cust) { const r = await sb.from('customers').insert({ user_id: userId }).select('id').maybeSingle(); cust = r.data; if (r.error) console.log('  (customers insert:', r.error.message.slice(0, 120), ')'); }
  const { data: anyVendor } = await sb.from('vendors').select('id').limit(1).maybeSingle();
  let orderId = null, escrowMade = false;
  if (cust?.id && anyVendor?.id) {
    const { data: ord, error: ordErr } = await sb.from('orders').insert({ customer_id: cust.id, vendor_id: anyVendor.id, total_amount: 5000, subtotal: 5000, status: 'pending', payment_status: 'paid', shipping_address: 'Test Adresse' }).select('id').maybeSingle();
    if (ordErr) console.log('  (orders insert:', ordErr.message.slice(0, 120), ')');
    orderId = ord?.id || null;
    if (orderId) {
      const { error: escErr } = await sb.from('escrow_transactions').insert({ order_id: orderId, payer_id: userId, receiver_id: null, amount: 5000, currency: 'GNF', status: 'held' });
      if (escErr) console.log('  (escrow insert:', escErr.message.slice(0, 120), ')');
      else escrowMade = true;
    }
  }
  console.log(`— FIXTURE — customer=${!!cust?.id}, order=${!!orderId}, escrow=${escrowMade}`);

  // Vérifs AVANT.
  const beforeProfile = (await sb.from('profiles').select('id').eq('id', userId).maybeSingle()).data;
  const beforeWallet = (await sb.from('wallets').select('user_id').eq('user_id', userId).maybeSingle()).data;
  log(`— AVANT — profil=${!!beforeProfile}, wallet=${!!beforeWallet}`);

  // Suppression via la logique partagée.
  const { deleteUserCompletely } = await import('../src/services/userDeletion.service.ts');
  const result = await deleteUserCompletely(userId, { actorId: userId, deletionReason: 'e2e test', deletionMethod: 'e2e' });

  let pass = true;
  pass &= ok(result.success && result.authDeleted, `(0) Service: success=${result.success}, authDeleted=${result.authDeleted}`);

  const afterProfile = (await sb.from('profiles').select('id').eq('id', userId).maybeSingle()).data;
  const afterWallet = (await sb.from('wallets').select('user_id').eq('user_id', userId).maybeSingle()).data;
  const { data: authAfter } = await sb.auth.admin.getUserById(userId);
  const { data: archive } = await sb.from('deleted_users_archive').select('original_user_id').eq('original_user_id', userId).maybeSingle();

  pass &= ok(!afterProfile, `(1) profiles supprimé (reste=${!!afterProfile})`);
  pass &= ok(!afterWallet, `(2) wallets supprimé (reste=${!!afterWallet})`);
  pass &= ok(!authAfter?.user, `(3) compte auth.users supprimé (reste=${!!authAfter?.user})`);
  pass &= ok(!!archive, `(4) archive 365j présente (restaurable) = ${!!archive}`);

  // Nettoyage de l'archive de test.
  try { await sb.from('deleted_users_archive').delete().eq('original_user_id', userId); } catch {}

  log(pass ? '\n🎉 SUCCÈS : suppression complète jusqu\'à la base (profil + wallet + auth.users), avec archive restaurable.' : '\n⚠️  ÉCHEC.');
  process.exit(pass ? 0 : 2);
}
main().catch((e) => { console.error('💥', e); process.exit(1); });
