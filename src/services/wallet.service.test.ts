/**
 * 🧪 Transfert P2P SÛR EN MULTI-WALLETS — tests du chantier 1 (failles 1 & 2 & 3).
 *
 * Le magasin `wallets` est en mémoire ; les écritures respectent le CAS (`.eq('balance', before)`)
 * exactement comme PostgREST. Les RPC atomiques déplacent l'argent sur CE magasin (chemin nominal),
 * et on peut les FORCER à échouer (`ctrl.rpcShouldFail`) pour exercer le REPLI MANUEL.
 *
 * « Ledger » = soldes des wallets AVANT/APRÈS (assertés). Devise à décimale zéro (GNF/XOF) → entiers.
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';

const h = vi.hoisted(() => {
  type W = { id: string; user_id: string; balance: number; currency: string; is_blocked: boolean };
  const store = {
    wallets: new Map<string, W>(),
    idempotency: new Set<string>(),
    seq: 1,
  };
  const ctrl = { rpcShouldFail: false };

  const matchWallet = (w: W, filters: [string, unknown][]) =>
    filters.every(([col, val]) =>
      col === 'balance' ? Number(w.balance) === Number(val) : (w as any)[col] === val);

  const applyPatch = (w: W, patch: any) => {
    if (patch == null) return;
    if ('balance' in patch) w.balance = Number(patch.balance);
    if ('currency' in patch) w.currency = String(patch.currency);
    if ('is_blocked' in patch) w.is_blocked = !!patch.is_blocked;
  };

  function run(state: any) {
    const { table, op, filters, single, maybeSingle, returnsRows } = state;

    if (table === 'wallets') {
      const all = [...store.wallets.values()];
      if (op === 'select') {
        const rows = all.filter((w) => matchWallet(w, filters)).map((w) => ({ ...w }));
        if (single) return rows.length === 1 ? { data: rows[0], error: null } : { data: null, error: { code: 'PGRST116', message: 'not single' } };
        if (maybeSingle) return rows.length <= 1 ? { data: rows[0] ?? null, error: null } : { data: null, error: { message: 'multiple rows' } };
        return { data: rows, error: null };
      }
      if (op === 'insert') {
        const list = Array.isArray(state.payload) ? state.payload : [state.payload];
        const inserted = list.map((r: any) => {
          const id = r.id || `w_${store.seq++}`;
          const w: W = { id, user_id: r.user_id, balance: Number(r.balance ?? 0), currency: String(r.currency || 'GNF'), is_blocked: !!r.is_blocked };
          store.wallets.set(id, w);
          return { ...w };
        });
        if (single) return { data: inserted[0], error: null };
        if (returnsRows) return { data: inserted, error: null };
        return { data: null, error: null };
      }
      if (op === 'update') {
        const matched = all.filter((w) => matchWallet(w, filters));
        matched.forEach((w) => applyPatch(w, state.payload));
        const out = matched.map((w) => ({ ...w }));
        if (single) return out.length === 1 ? { data: out[0], error: null } : { data: null, error: { code: 'PGRST116', message: '0/many' } };
        if (returnsRows) return { data: out, error: null };
        return { data: null, error: null };
      }
      return { data: null, error: null };
    }

    if (table === 'wallet_idempotency_keys') {
      if (op === 'select') {
        const key = (filters.find(([c]: any) => c === 'idempotency_key') || [])[1];
        const exists = store.idempotency.has(key);
        if (maybeSingle) return { data: exists ? { id: 'idem' } : null, error: null };
        return { data: exists ? [{ id: 'idem' }] : [], error: null };
      }
      if (op === 'insert') {
        const list = Array.isArray(state.payload) ? state.payload : [state.payload];
        for (const r of list) {
          if (store.idempotency.has(r.idempotency_key)) return { data: null, error: { code: '23505', message: 'unique_violation' } };
          store.idempotency.add(r.idempotency_key);
        }
        return { data: null, error: null };
      }
      if (op === 'delete') {
        const key = (filters.find(([c]: any) => c === 'idempotency_key') || [])[1];
        store.idempotency.delete(key);
        return { data: null, error: null };
      }
      return { data: null, error: null };
    }

    if (table === 'wallet_logs') return { data: [], error: null };

    // wallet_transactions / enhanced_transactions / wallet_suspicious_activities : acceptation neutre.
    return { data: returnsRows ? [] : null, error: null };
  }

  function createFrom(table: string) {
    const state: any = { table, op: 'select', filters: [], payload: null, single: false, maybeSingle: false, returnsRows: false };
    const exec = () => Promise.resolve().then(() => run(state));
    const builder: any = {
      select(_cols?: string) { state.returnsRows = true; return builder; },
      insert(payload: any) { state.op = 'insert'; state.payload = payload; return builder; },
      update(payload: any) { state.op = 'update'; state.payload = payload; return builder; },
      delete() { state.op = 'delete'; return builder; },
      upsert(payload: any) { state.op = 'upsert'; state.payload = payload; return builder; },
      eq(col: string, val: unknown) { state.filters.push([col, val]); return builder; },
      gte() { return builder; },
      or() { return builder; },
      in() { return builder; },
      order() { return builder; },
      limit() { return builder; },
      single() { state.single = true; return exec(); },
      maybeSingle() { state.maybeSingle = true; return exec(); },
      then(res: any, rej: any) { return exec().then(res, rej); },
    };
    return builder;
  }

  const client = {
    from: (table: string) => createFrom(table),
    async rpc(name: string, params: any) {
      if (name === 'execute_atomic_wallet_transfer' || name === 'execute_atomic_wallet_transfer_fx') {
        if (ctrl.rpcShouldFail) return { data: null, error: { message: 'infra: connection reset by peer' } };
        const sw = store.wallets.get(params.p_sender_wallet_id);
        const rw = store.wallets.get(params.p_recipient_wallet_id);
        const debit = name === 'execute_atomic_wallet_transfer' ? params.p_amount : params.p_debit_amount;
        const credit = name === 'execute_atomic_wallet_transfer' ? params.p_amount : params.p_credit_amount;
        if (sw) sw.balance = Number(sw.balance) - Number(debit);
        if (rw) rw.balance = Number(rw.balance) + Number(credit);
        return { data: { transaction_id: `tx_rpc_${store.seq++}` }, error: null };
      }
      return { data: null, error: { message: `unmocked rpc ${name}` } };
    },
  };

  return { store, ctrl, client };
});

vi.mock('../config/logger.js', () => ({ logger: { info() {}, warn() {}, error() {}, debug() {} } }));
vi.mock('../config/supabase.js', () => ({ supabaseAdmin: h.client }));

import { transferBetweenWallets, selectSenderWallet } from './wallet.service.js';

// Helpers de test
const seedWallet = (id: string, user_id: string, balance: number, currency: string, is_blocked = false) => {
  h.store.wallets.set(id, { id, user_id, balance, currency, is_blocked });
};
const bal = (id: string) => h.store.wallets.get(id)!.balance;

beforeEach(() => {
  h.store.wallets.clear();
  h.store.idempotency.clear();
  h.store.seq = 1000;
  h.ctrl.rpcShouldFail = false;
});

describe('Transfert P2P multi-wallets — chantier 1', () => {
  // 1) A(GNF) → B(GNF) : OK, débit = crédit (frais 0 en national).
  it('1. GNF→GNF : débité = crédité, soldes cohérents', async () => {
    seedWallet('A_gnf', 'A', 10_000, 'GNF');
    seedWallet('B_gnf', 'B', 2_000, 'GNF');

    const r = await transferBetweenWallets('A', 'B', 3_000, 'test', 'key-1', {
      amountToCredit: 3_000, senderCurrency: 'GNF', receiverCurrency: 'GNF',
      senderWalletId: 'A_gnf', receiverWalletId: 'B_gnf', feeAmount: 0,
    });

    expect(r.success).toBe(true);
    expect(bal('A_gnf')).toBe(7_000);  // 10 000 - 3 000
    expect(bal('B_gnf')).toBe(5_000);  // 2 000 + 3 000
  });

  // 2) A(GNF+XOF) → B : envoi GNF débite le wallet GNF de A, PAS le XOF (faille 1, côté expéditeur).
  it('2. expéditeur multi-wallets : le GNF est débité, le XOF INTACT', async () => {
    seedWallet('A_gnf', 'A', 10_000, 'GNF');
    seedWallet('A_xof', 'A', 8_000, 'XOF');
    seedWallet('B_gnf', 'B', 0, 'GNF');

    // Pas de senderWalletId → le service sélectionne par devise (GNF prioritaire).
    const r = await transferBetweenWallets('A', 'B', 4_000, 'test', 'key-2', {});

    expect(r.success).toBe(true);
    expect(bal('A_gnf')).toBe(6_000);  // débité
    expect(bal('A_xof')).toBe(8_000);  // ⬅️ INTACT
    expect(bal('B_gnf')).toBe(4_000);  // crédité
  });

  // 3) A → B(GNF+XOF) : le GNF de B crédité, le XOF de B INTACT (faille 1/2, côté destinataire — RPC).
  it('3. destinataire multi-wallets : le GNF crédité, le XOF INTACT', async () => {
    seedWallet('A_gnf', 'A', 10_000, 'GNF');
    seedWallet('B_gnf', 'B', 1_000, 'GNF');
    seedWallet('B_xof', 'B', 5_000, 'XOF');

    const r = await transferBetweenWallets('A', 'B', 2_500, 'test', 'key-3', {});

    expect(r.success).toBe(true);
    expect(bal('A_gnf')).toBe(7_500);
    expect(bal('B_gnf')).toBe(3_500);  // 1 000 + 2 500
    expect(bal('B_xof')).toBe(5_000);  // ⬅️ INTACT
  });

  // 4) LE TEST QUI TUE LA FAILLE 2 : repli manuel forcé sur le cas 3 → mêmes garanties.
  //    L'ancien code créditait par user_id → écrasait TOUS les wallets de B. Ici : XOF doit rester intact.
  it('4. REPLI MANUEL (RPC forcé en échec) : GNF crédité par id+CAS, XOF INTACT', async () => {
    seedWallet('A_gnf', 'A', 10_000, 'GNF');
    seedWallet('B_gnf', 'B', 1_000, 'GNF');
    seedWallet('B_xof', 'B', 5_000, 'XOF');
    h.ctrl.rpcShouldFail = true;   // force le repli manuel

    const r = await transferBetweenWallets('A', 'B', 2_500, 'test', 'key-4', {});

    expect(r.success).toBe(true);
    expect(bal('A_gnf')).toBe(7_500);   // débité par id+CAS
    expect(bal('B_gnf')).toBe(3_500);   // crédité par id+CAS
    expect(bal('B_xof')).toBe(5_000);   // ⬅️ INTACT (faille 2 fermée)
  });

  // 5) Devise sans wallet → erreur claire, ZÉRO mouvement.
  it('5. devise expéditeur sans wallet : erreur claire, aucun débit', async () => {
    seedWallet('A_gnf', 'A', 10_000, 'GNF');
    seedWallet('B_gnf', 'B', 0, 'GNF');

    const r = await transferBetweenWallets('A', 'B', 1_000, 'test', 'key-5', { senderCurrency: 'USD' });

    expect(r.success).toBe(false);
    expect(r.error).toMatch(/wallet USD/i);
    expect(bal('A_gnf')).toBe(10_000);  // ⬅️ ZÉRO mouvement
    expect(bal('B_gnf')).toBe(0);

    // Contrôle direct du helper : même verdict.
    const sel = await selectSenderWallet('A', 'USD');
    expect(sel.error).toMatch(/wallet USD/i);
  });

  // 7) Deux transferts simultanés du même expéditeur, solde pour UN seul → un seul passe (CAS prouvé).
  //    Clés d'idempotence DIFFÉRENTES (sinon dé-dup) → les deux passent le verrou et courent sur le solde.
  it('7. concurrence : solde pour un seul → exactement un réussit (CAS)', async () => {
    seedWallet('A_gnf', 'A', 3_000, 'GNF');   // assez pour UN transfert de 3 000
    seedWallet('B_gnf', 'B', 0, 'GNF');
    h.ctrl.rpcShouldFail = true;   // repli manuel → CAS explicite des deux côtés

    const [r1, r2] = await Promise.all([
      transferBetweenWallets('A', 'B', 3_000, 'test', 'key-7a', { senderWalletId: 'A_gnf', receiverWalletId: 'B_gnf', senderCurrency: 'GNF', receiverCurrency: 'GNF' }),
      transferBetweenWallets('A', 'B', 3_000, 'test', 'key-7b', { senderWalletId: 'A_gnf', receiverWalletId: 'B_gnf', senderCurrency: 'GNF', receiverCurrency: 'GNF' }),
    ]);

    const successes = [r1, r2].filter((r) => r.success).length;
    expect(successes).toBe(1);          // ⬅️ un SEUL passe
    expect(bal('A_gnf')).toBe(0);        // exactement un débit
    expect(bal('B_gnf')).toBe(3_000);    // exactement un crédit (pas de double-dépense)
  });
});
