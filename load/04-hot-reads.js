// Scénario 4 — LECTURES CHAUDES (profil + solde + notifications) : 100 → 500 VUs.
import http from 'k6/http';
import { BASE_URL, READ_THRESHOLDS, loadTokens, pickForVU, authHeaders, ok2xx } from './config.js';
import { vu } from 'k6/execution';

export const options = {
  scenarios: {
    reads: {
      executor: 'ramping-vus', startVUs: 100,
      stages: [{ duration: '2m', target: 500 }, { duration: '5m', target: 500 }, { duration: '30s', target: 0 }],
    },
  },
  thresholds: READ_THRESHOLDS,
};

const TOKENS = loadTokens();

export default function () {
  const t = pickForVU(TOKENS, vu.idInTest);
  if (!t) return;
  const h = authHeaders(t.token);
  ok2xx(http.get(`${BASE_URL}/api/v2/wallet/balance`, { ...h, tags: { name: 'balance' } }), 'balance');
  ok2xx(http.get(`${BASE_URL}/api/v2/wallet/transactions?limit=10`, { ...h, tags: { name: 'txns' } }), 'txns');
}
