# 🏋️ Tests de charge k6 — backend 224Solutions

**JAMAIS contre la prod.** Uniquement un staging avec données de test seedées.

## 1. Monter le staging
- Backend en cluster : `pm2 start ecosystem.config.cjs` (Redis partagé requis).
- DB : projet Supabase de staging (jamais la prod). Activer `pg_stat_statements`.
- Seeder :
  - N utilisateurs de test avec mot de passe connu → `USERS` (scénario login).
  - Chaque utilisateur : wallet provisionné (solde suffisant), un `recipientCode`
    (code d'un AUTRE utilisateur de test), et un `cart` (2 vendeurs) →
    fichier `tokens.json` : `[{ token, userId, walletId, recipientCode, cart }]`.
  - Récupérer les `token` via un login réel (le seed script les collecte).

## 2. Lancer un scénario
```bash
export BASE_URL=https://staging-api.224solutions.xxx
export TOKENS="$(cat tokens.json)"
k6 run load/01-login.js  -e USERS="$(cat users.json)"
k6 run load/02-wallet-transfer.js
k6 run load/03-create-order.js
k6 run load/04-hot-reads.js
k6 run load/05-mixed.js
```
Le tir ÉCHOUE (exit ≠ 0) si un seuil (`thresholds`) casse : p95 lectures < 800 ms,
p95 écritures argent < 2 s, erreurs < 0,5 % (les 429 du rate-limiter sont exclus).

## 3. APRÈS chaque scénario — invariants d'argent (OBLIGATOIRE)
```bash
psql "$STAGING_DB_URL" -f load/invariants.sql
```
Toutes les lignes doivent renvoyer **0 violation**. Sinon : incohérence d'argent → le
tir est un ÉCHEC, investiguer avant toute mise à l'échelle.

## 4. Mesures à collecter pendant le tir
- `pm2 monit` : CPU/RAM par worker.
- Supabase dashboard : connexions, IOPS, slow queries ;
  `SELECT * FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 10;`
- Realtime : compter les canaux consommés avec 1 front de test ouvert → extrapoler
  le plafond du plan (le front ouvre ~141 canaux ; le plan Supabase borne les
  connexions realtime simultanées).

## 5. Remplir le rapport
Pour chaque scénario : VUs max tenus dans les seuils, ressource limitante (CPU worker /
DB / realtime), et la ligne « le système tient X req/s simultanées ≈ Y inscrits actifs »
avec le raisonnement (req/utilisateur actif/min → utilisateurs simultanés).
