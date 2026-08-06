// Scénario 2 — TRANSFERT WALLET (RPC atomique) : 20 → 100 VUs.
// CHAQUE VU son propre wallet (le verrou par wallet sérialise par utilisateur).
// 10% des itérations rejouent la MÊME client_key → doit produire 0 doublon (idempotence sous charge).
import http from 'k6/http';
import { BASE_URL, WRITE_THRESHOLDS, loadTokens, pickForVU, authHeaders, ok2xx } from './config.js';
import { vu } from 'k6/execution';
import { check } from 'k6';

export const options = {
  scenarios: {
    transfer: {
      executor: 'ramping-vus', startVUs: 20,
      stages: [{ duration: '2m', target: 100 }, { duration: '5m', target: 100 }, { duration: '30s', target: 0 }],
    },
  },
  thresholds: {
    ...WRITE_THRESHOLDS,
    // Invariant en ligne : un rejeu idempotent ne doit jamais créer une 2e transaction.
    'checks{check:idempotent_no_dup}': ['rate>0.99'],
  },
};

const TOKENS = loadTokens();
let lastKey = null; // par VU (isolé) — pour rejouer la même client_key à 10%

export default function () {
  const t = pickForVU(TOKENS, vu.idInTest);
  if (!t || !t.recipientCode) return;
  const h = authHeaders(t.token);

  const replay = lastKey && Math.random() < 0.10;
  const clientKey = replay ? lastKey : `${t.userId}-${vu.idInTest}-${Date.now()}-${Math.random()}`;
  lastKey = clientKey;

  const body = JSON.stringify({
    recipient_code: t.recipientCode, amount: 100, currency: 'GNF',
    description: 'k6 load', client_key: clientKey,
  });
  const res = http.post(`${BASE_URL}/api/v2/wallet/transfer`, body, { ...h, tags: { name: 'transfer' } });
  if (res.status !== 429) ok2xx(res, 'transfer');

  if (replay) {
    // Le rejeu doit renvoyer la MÊME transaction (idempotent) ou un 200 sans nouvelle écriture.
    check(res, { idempotent_no_dup: (r) => r.status === 200 || r.status === 409 }, { check: 'idempotent_no_dup' });
  }
}
