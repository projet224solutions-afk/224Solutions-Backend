// Config partagée des tirs k6. Tout est paramétré par variables d'env (jamais la prod).
// Ex : k6 run -e BASE_URL=https://staging.api.224 -e TOKENS_FILE=./tokens.json load/05-mixed.js
import { check } from 'k6';

export const BASE_URL = __ENV.BASE_URL || 'http://localhost:3001';

// Seuils COMMUNS (le test ÉCHOUE si cassés) — cf. cahier des charges §2.3.
export const READ_THRESHOLDS = {
  http_req_duration: ['p(95)<800'],           // lectures : p95 < 800 ms
  http_req_failed: ['rate<0.005'],            // < 0,5 % d'erreur (429 exclus via tag)
};
export const WRITE_THRESHOLDS = {
  http_req_duration: ['p(95)<2000'],          // écritures argent : p95 < 2 s
  http_req_failed: ['rate<0.005'],
};

// Jetons seedés côté staging : un tableau { token, userId, walletId, recipientCode }.
// Fournis via -e TOKENS='[...]' ou un fichier importé par le scénario.
export function loadTokens() {
  const raw = __ENV.TOKENS || '[]';
  try { return JSON.parse(raw); } catch { return []; }
}

// Un VU = un utilisateur distinct (indispensable pour le transfert : le verrou par wallet
// sérialise par utilisateur ; un test mono-wallet mesurerait le verrou, pas le système).
export function pickForVU(tokens, vuId) {
  if (tokens.length === 0) return null;
  return tokens[(vuId - 1) % tokens.length];
}

export function authHeaders(token) {
  return { headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' } };
}

export function ok2xx(res, name) {
  return check(res, { [`${name} 2xx`]: (r) => r.status >= 200 && r.status < 300 });
}
