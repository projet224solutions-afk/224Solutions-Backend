// Scénario 5 — MIXTE RÉALISTE : 70% lectures / 20% commandes / 10% transferts, 30 min.
import http from 'k6/http';
import { BASE_URL, loadTokens, pickForVU, authHeaders, ok2xx } from './config.js';
import { vu } from 'k6/execution';

export const options = {
  scenarios: {
    mixed: {
      executor: 'ramping-vus', startVUs: 50,
      stages: [{ duration: '3m', target: 200 }, { duration: '30m', target: 200 }, { duration: '1m', target: 0 }],
    },
  },
  thresholds: {
    'http_req_duration{name:balance}': ['p(95)<800'],
    'http_req_duration{name:transfer}': ['p(95)<2000'],
    'http_req_duration{name:create_order}': ['p(95)<2000'],
    http_req_failed: ['rate<0.005'],
  },
};

const TOKENS = loadTokens();

export default function () {
  const t = pickForVU(TOKENS, vu.idInTest);
  if (!t) return;
  const h = authHeaders(t.token);
  const dice = Math.random();
  if (dice < 0.70) {
    ok2xx(http.get(`${BASE_URL}/api/v2/wallet/balance`, { ...h, tags: { name: 'balance' } }), 'balance');
  } else if (dice < 0.90 && t.cart) {
    const line = t.cart[0];
    http.post(`${BASE_URL}/api/orders`, JSON.stringify({ vendor_id: line.vendor_id, items: line.items, payment_method: 'wallet', payment_confirmed: true }), { ...h, tags: { name: 'create_order' } });
  } else if (t.recipientCode) {
    http.post(`${BASE_URL}/api/v2/wallet/transfer`, JSON.stringify({ recipient_code: t.recipientCode, amount: 100, currency: 'GNF', description: 'k6 mixed', client_key: `${t.userId}-${Date.now()}-${Math.random()}` }), { ...h, tags: { name: 'transfer' } });
  }
}
