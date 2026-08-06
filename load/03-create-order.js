// Scénario 3 — CRÉATION COMMANDE MARKETPLACE : 20 → 100 VUs, panier 2 vendeurs.
import http from 'k6/http';
import { BASE_URL, WRITE_THRESHOLDS, loadTokens, pickForVU, authHeaders, ok2xx } from './config.js';
import { vu } from 'k6/execution';

export const options = {
  scenarios: {
    orders: {
      executor: 'ramping-vus', startVUs: 20,
      stages: [{ duration: '2m', target: 100 }, { duration: '5m', target: 100 }, { duration: '30s', target: 0 }],
    },
  },
  thresholds: WRITE_THRESHOLDS,
};

const TOKENS = loadTokens();

export default function () {
  const t = pickForVU(TOKENS, vu.idInTest);
  if (!t || !t.cart) return; // t.cart = [{ vendor_id, items:[{product_id, quantity}] }, ...] seedé
  const h = authHeaders(t.token);
  // Une commande par vendeur du panier (le backend crée 1 order/vendeur).
  for (const line of t.cart) {
    const res = http.post(`${BASE_URL}/api/orders`, JSON.stringify({
      vendor_id: line.vendor_id, items: line.items,
      payment_method: 'wallet', payment_confirmed: true,
    }), { ...h, tags: { name: 'create_order' } });
    if (res.status !== 429) ok2xx(res, 'create_order');
  }
}
