// Scénario 1 — LOGIN : 50 → 200 VUs, ramp 2 min, plateau 5 min.
import http from 'k6/http';
import { BASE_URL, READ_THRESHOLDS, ok2xx } from './config.js';

export const options = {
  scenarios: {
    login: {
      executor: 'ramping-vus',
      startVUs: 50,
      stages: [
        { duration: '2m', target: 200 },   // ramp
        { duration: '5m', target: 200 },   // plateau
        { duration: '30s', target: 0 },
      ],
    },
  },
  thresholds: READ_THRESHOLDS,
};

// Comptes de test seedés : -e USERS='[{"identifier":"+224...","password":"..."}]'
const USERS = JSON.parse(__ENV.USERS || '[]');

export default function () {
  if (USERS.length === 0) return;
  const u = USERS[Math.floor(Math.random() * USERS.length)];
  const res = http.post(`${BASE_URL}/api/auth/login`,
    JSON.stringify({ identifier: u.identifier, password: u.password }),
    { headers: { 'Content-Type': 'application/json' }, tags: { name: 'login' } });
  // 429 = rate-limit volontaire (auth failClosed) → ne compte pas comme échec.
  if (res.status !== 429) ok2xx(res, 'login');
}
