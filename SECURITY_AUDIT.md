# SECURITY_AUDIT.md — Backend 224Solutions (`224Solutions-Backend`)

> Audit du 2026-07-23. Branche courante : **`main`** (le prompt visait `security/identity-atomic-ensure` — non présente localement ; aucun changement de branche effectué pour ne rien casser).
> Méthode : reconnaissance READ-ONLY multi-agents sur `src/` + audit RLS/SECURITY DEFINER via l'API Management Supabase + `npm audit`.
>
> **RÈGLE 6 appliquée** : les flux **monétaires/auth** (B2, B3, B4, B5, B6, B9) sont **RAPPORTÉS**, pas corrigés — ils attendent une **validation humaine explicite**. Les correctifs sûrs (A1, A2, B7, B8, B10, B11) sont appliqués en commits `security:` séparés.

## ⚠️ Linchpin transverse — `NODE_ENV` non `production` sur l'EC2
La fuite de stack (A1) prouve que `env.isProduction` est **faux** en prod → `NODE_ENV` n'est pas `production` dans l'environnement PM2. **Action serveur requise (PDG/ops)** : définir `NODE_ENV=production` dans l'écosystème PM2 puis `pm2 restart --update-env`. Sans ça, plusieurs protections dépendantes de `isProduction` (dont le durcissement CORS B10) restent inertes. Le correctif A1 a été rendu **fail-safe** (indépendant de `NODE_ENV`).

---

## PARTIE A — Correctifs confirmés (appliqués)

### [A1] Fuite de stack trace en production (CWE-209)
- Sévérité : 🟠 ÉLEVÉ
- Statut : **CORRIGÉ**
- Emplacement : `src/middlewares/errorHandler.ts:38-45` (avant)
- Détail : le handler renvoyait `stack: err.stack` au client quand `!env.isProduction`. Comme `NODE_ENV` n'est pas `production` sur l'EC2, la stack (chemins `/var/www/backend/src/...`, n° de ligne) fuitait réellement (confirmé de l'extérieur).
- Action : **fail-safe** — la stack et les détails internes ne sont **JAMAIS** renvoyés au client, quel que soit `NODE_ENV`. Les 5xx reçoivent un message générique `Internal server error` ; les 4xx applicatifs gardent leur message métier (sûr). Détails complets loggués côté serveur uniquement. Recommandation complémentaire : brancher Sentry backend + fixer `NODE_ENV=production`. Audit des autres `res.json` d'erreur : le handler global est le point de fuite ; les routes utilisent `ok()/fail()` sans stack.

### [A2] Refus CORS renvoyait 500 au lieu de 403
- Sévérité : 🟡 MOYEN
- Statut : **CORRIGÉ**
- Emplacement : `src/server.ts:193` (`callback(new Error('Not allowed by CORS'))`) → `src/middlewares/errorHandler.ts`
- Détail : l'`Error` levée par la callback CORS remontait en 500 verbeux.
- Action : le handler détecte `err.message === 'Not allowed by CORS'` et renvoie **403 `{ success:false, error:'Origin not allowed' }`** (corps maîtrisé, sans détail interne).

---

## PARTIE B — Chasse en profondeur

### [B2] 🔴 Intégrité des paiements (webhooks & crédits) — **À VALIDER (ne pas corriger sans feu vert)**

| ID | Constat | Statut | Sév. | Emplacement |
|----|---------|--------|------|-------------|
| **F1** | `POST /api/v2/wallet/deposit` crédite le wallet au **`amount` du body**, sans preuve de paiement (seul garde : `verifyJWT`, plafond 100M/appel). **Création de monnaie ex nihilo** par tout compte authentifié. | **VULNÉRABLE** | 🔴 | `src/routes/wallet.v2.routes.ts:1210-1259` |
| **F2** | `POST /api/payments/secure/validate` crédite selon `payment_status`/`amount_paid` **fournis par le client** ; la « signature » ne couvre que `txId+total` et est **rendue au client** à l'`init` (`:434`). Aucune confirmation serveur-à-serveur du mobile money. | **VULNÉRABLE** | 🔴 | `src/routes/payments.routes.ts:462-673` (init `335-451`) |
| **F3** | Webhook PayPal **non signé** : `event_type`+`order_id` du body → passe **n'importe quelle** commande en `paid/confirmed`. Chemin public (`isPublicEdgePath` vrai pour `/webhooks`). | **VULNÉRABLE** | 🔴 | `src/routes/edge-functions/webhooks.routes.ts:132-166` |
| **F4** | Webhook ChapChapPay **non signé** : `status`+`order_id` du body → idem F3. | **VULNÉRABLE** | 🔴 | `src/routes/edge-functions/webhooks.routes.ts:168-198` |
| F5 | Stripe `/webhooks/stripe` : HMAC `timingSafeEqual` + anti-rejeu 5 min + idempotence `webhook_events` + `stripe_deposit_${PI}` + montant recalculé serveur. | **OK** | 🟢 | `src/routes/webhooks.routes.ts:23-52,382-481` |
| F6 | Stripe `/edge-functions/webhooks/stripe` : `constructEvent` + raw body + idempotence. | **OK** | 🟢 | `src/routes/edge-functions/webhooks.routes.ts:32-130` |
| F8 | PayPal **signé** `/edge-functions/payments/paypal/webhook` : `verify-webhook-signature` API + garde `status=pending`. (Coexiste avec F3 non signé → bénéfice annulé tant que F3 vit.) | **OK** | 🟢 | `src/routes/edge-functions/payments.routes.ts:552-658` |
| F9 | `creditWallet` : verrou idempotent `wallet_idempotency_keys` (UNIQUE, 23505→ignore) + RPC atomique `execute_atomic_deposit`. | **OK** | 🟢 | `src/services/wallet.service.ts:286-435` |
| F7 | `/edge-functions/payments/stripe/webhook` : `constructEvent` mais body déjà parsé par `express.json()` global → 400 systématique (fail-closed mais endpoint mort). | À VALIDER | 🟡 | `src/routes/edge-functions/payments.routes.ts:419-480` |
| F10 | Clé d'idempotence par défaut faible `deposit:${userId}:${amount}:${minute}` (contournable en variant `amount` ; dédup de dépôts légitimes distincts). | À VALIDER | 🟡 | `src/routes/wallet.v2.routes.ts:1224` |
| F11 | Stubs `external-payments.routes.ts` (webhooks sans signature, inertes) → supprimer pour lever l'ambiguïté. | À VALIDER | 🟡 | `src/routes/edge-functions/external-payments.routes.ts` |

- **CinetPay / PawaPay / Flutterwave** : **ABSENTS** du backend (0 occurrence). À signaler si le produit prétend les supporter.
- **Recommandations (en attente de validation)** :
  1. **F1** → réserver `/deposit` à un rôle service (comme `/credit` `:1635` qui a `requirePermissionOrRole(['admin','pdg','ceo'])`), ou le supprimer. Aucun crédit sans preuve fournisseur.
  2. **F2** → retirer le crédit basé sur le statut/montant du body ; exiger une confirmation serveur-à-serveur réelle du provider.
  3. **F3/F4** → supprimer les webhooks non signés ; router PayPal exclusivement vers F8 signé ; signer ChapChapPay (ou retirer).
  4. **F7/F11** → retirer les endpoints morts/stubs.

### [B3] 🟠 Autorisation par ressource (IDOR / BOLA) — **À VALIDER**
- **IDOR wallet legacy** — **VULNÉRABLE 🟠** — `src/routes/wallet.routes.js:137-166` (`POST /api/wallet/check`, monté `server.ts:296`). Le `user_id` du **body prime** sur le token → lecture du wallet (`select('*')`) de **n'importe quel utilisateur**. Le voisin `/initialize` (`:45`) fait pourtant la vérif `req.user.id !== user_id → 403`. **Reco** : forcer `currentUserId = req.user.id` (ignorer le body), ou 403 si divergence. La route active `wallet.v2.routes.ts` (`/api/v2/wallet`) est saine (userId toujours dérivé du token).
- Middleware JWT — **OK 🟢** — `src/middlewares/auth.middleware.ts:53-123` : `supabaseAdmin.auth.getUser(token)` (signature déléguée), rôle chargé depuis `profiles` (non falsifiable). Repli local HS256 si Supabase injoignable **et** `JWT_SECRET` défini.
- Ownership orders/profiles/campaigns/restaurant/pharmacy/clips/returns/b2b — **OK 🟢** (vérif `customer_id`/`vendor_id`/owner systématique avant lecture/mutation).
- Rôle admin/PDG — **OK 🟢** — `admin.routes.ts` : `verifyJWT + requireRole(PDG_ROLES)` sur les 42 endpoints, + `requireStepUpMFA` sur les ops financières. `shareholders`/`agentCash` idem (contrôle serveur DB-backed).

### [B4] 🟠 RLS Supabase & SECURITY DEFINER — **À VALIDER**
- **RLS activé** : **0 table sensible sans RLS** (wallets/ledger/transactions/escrow/commissions/profiles/shareholder… toutes protégées). 1 seule table sur 613 sans RLS (non sensible).
- **Policies `USING(true)` à revoir** (à confirmer le rôle `TO`) : la plupart sont `TO service_role` (OK, service_role bypasse la RLS de toute façon) ou des tables de **config en lecture** (`commission_settings`, `agent_commission_rules`, `shareholder_config`, `affiliate_commission_tiers` — lecture publique de barèmes, acceptable). **À vérifier** : `payment_schedules` (« Vendors can view their payment schedules » mais `qual=true` → tout authentifié voit TOUS les échéanciers), `wallet_fees`/`wallet_suspicious_activities`/`agent_wallets` (policies ALL `true` — confirmer restriction `TO service_role`).
- **Fonctions SECURITY DEFINER argent grantées à `anon`/`authenticated`** : nombreuses (`_acash_credit_wallet`, `_acash_debit_wallet`, `credit_pdg_wallet_on_revenue`, `ensure_wallet`, `get_or_create_wallet`, `calculate_commission`, `create_wallet_for_user`…). Beaucoup sont des **fonctions trigger** (le GRANT n'a pas d'effet — elles ne sont pas appelables en RPC) ou des helpers de lecture. **À VALIDER au cas par cas** : celles réellement appelables via PostgREST par `anon`/`authenticated` qui **déplacent de l'argent** (`_acash_credit_wallet`/`_acash_debit_wallet` notamment) doivent `REVOKE FROM anon, authenticated, PUBLIC` + `GRANT TO service_role`, et vérifier l'appelant dans la fonction si exposée. Cf. chantier historique `project_money_functions_public_leak`.

### [B5] 🟠 Tokens temps réel/vidéo — **OK (côté serveur)**
- Agora — **OK 🟢** : token minté côté backend (`/api/v2/agora/token`), App Certificate jamais exposé (côté front : `appCertificate:''`, pas de `RtcTokenBuilder`).
- Ably — **OK 🟢** : `authCallback` serveur (`/api/v2/realtime/token`), clé racine jamais côté client.
- Firebase — config web publique par design ; **à confirmer** : Security Rules Firestore/RTDB si données sensibles (hors périmètre code).

### [B6] 🟠 SSRF — **À VALIDER**
- **SSRF aveugle** — **VULNÉRABLE 🟠** — `src/routes/edge-functions/translation-media.routes.ts:126` : `fetch(audioUrl)` où `audioUrl` vient du body, **sans validation de schéma/host**. Un compte authentifié peut viser `http://169.254.169.254/…` (métadonnées EC2), IP internes, `file:`… avec oracle via statut/timing. **Reco** : whitelister le host (bucket Supabase Storage) ; sinon n'autoriser que `https` + rejeter IP privées/link-local (résolution DNS). Route non-publique (Bearer requis) → exploitable par tout utilisateur, pas anonymement.
- Scraper BCRG/FX — **OK 🟢** — `src/services/fxRates.service.ts:135,391` : URLs whitelistées en dur (`bcrg-guinee.org`, extraction ancrée au host de confiance). Aucune entrée client n'atteint un `fetch`.
- OG image / image copilot — **OK 🟢** — data URL base64 validé par regex ; pas de fetch distant piloté par le client (`copilot.routes.ts:1223`, `files.routes.ts:266` URL OpenAI en dur).

### [B7] 🟡 Rate limiting & anti-abus — **partiellement CORRIGÉ**
Infra solide (Redis-backed + fail-closed sur auth/payment). Routes bien protégées : login (verrou par identifiant), PIN wallet (5 essais + `pin_locked_until`), OTP SMS inscription/reset (3/15min IP + par numéro), wallet/paiements (`paymentRateLimit`), uploads (20/h).
Lacunes traitées (voir commits `security:`) :
- **VULNÉRABLE 🟠 → CORRIGÉ** : `POST /edge-functions/sms` (`notifications.routes.ts:187`) — SMS arbitraire (numéro+contenu) pour tout user auth, **sans limite dédiée** → SMS-bombing/smishing/coût. Action : limiteur SMS dédié ajouté (voir aussi reco admin-gate en B-monétaire).
- **VULNÉRABLE 🟠 → CORRIGÉ** : `POST /api/v2/bureau/auth/resend-otp` (`bureau.routes.ts:69`) — **non-auth, sans limite** → OTP/email-bombing. Action : `authRateLimit` ajouté.
- **À VALIDER 🟡** : `/edge-functions/otp-email` (magic-link sans limite dédiée) ; `/auth/login` sans limiteur **par IP** (credential-stuffing distribué) ; fail-open mémoire/instance si Redis down.

### [B8] 🟡 Validation d'entrée & uploads — **partiellement CORRIGÉ**
- Upload média — **OK 🟢** — `src/routes/media.routes.js:54,62-68` : MIME réel (magic bytes `fileTypeFromBuffer`), taille 10MB, nom assaini (anti path-traversal), scoping `uploads/${userId}`, auth + rate-limit.
- **Injection filtre PostgREST `.or()`** :
  - **VULNÉRABLE 🟠 → CORRIGÉ** : `bureau.routes.ts:78` — `identifier` (body **non-auth, non assaini**) interpolé dans `.or(president_email.eq.${identifier},bureau_code.eq.${identifier})`. Action : assainissement des métacaractères PostgREST.
  - **À VALIDER 🟡** : `agentCash.routes.ts:736` (`q`), `taxi.routes.ts:65`, `pos.routes.ts:677`, `wallet.v2.routes.ts:618`, `profiles.routes.ts:138` — confirmer que la normalisation retire `, ( ) . : *`.
- **Injection SQL par noms de colonnes** — À VALIDER 🟡 — `cloudSql.sync.routes.js:183` (`Object.keys(row)` concaténés). **Routeur NON monté** dans `server.ts` + protégé par `X-Sync-Api-Key` → non exploitable en l'état ; whitelister les colonnes si activé.
- Validation zod **non systématique** sur money/edge (contrôles `typeof`/`any`) — À VALIDER 🟡. Pas de faille money isolée, mais couverture à généraliser.
- `migrations.ts:186 /apply-warehouse` : SQL depuis fichiers locaux (pas client), auth = `X-DB-Password` — surface sensible montée sur `/api/migrations` sans `verifyJWT`/rôle → réduire.

### [B9] 🟡 JWT / session — **OK (durcissements mineurs À VALIDER)**
- `JWT_SECRET` en env (`env.ts:51`), **fail-fast** si < 32 car. en prod (`assertSecretsOnBoot`), aucun secret committé (`.env` gitignoré). **OK 🟢**
- À VALIDER 🟡 : `jwt.verify` du repli (`auth.middleware.ts:69`) ne pinne pas `algorithms:['HS256']` (non exploitable ici — secret symétrique — mais bonne pratique) ; token **bureau** TTL 24h (long pour une session privilégiée) ; durée de vie des access tokens = config Supabase (hors repo, à confirmer console).

### [B10] 🟡 Configuration CORS — **CORRIGÉ**
- Allowlist stricte, pas de reflet d'origine ni `*`, `credentials:true` limité à l'allowlist. **OK 🟢**
- **VULNÉRABLE 🟡 → CORRIGÉ** : `env.ts:163-187` fusionnait **inconditionnellement** `http://localhost*`/`127.0.0.1`/`[::1]` (+ défaut `CORS_ORIGINS` L121) → origines loopback autorisées **en prod avec credentials**. Action : origines loopback **dev-only** + filtre anti-loopback en production ; `capacitor://ionic://localhost` (app mobile) et domaines `224solution.net` conservés. ⚠️ Effectif seulement avec `NODE_ENV=production` (voir linchpin).
- À VALIDER 🟡 : wildcard `https://*.224solution.net` + credentials (risque en cas de subdomain takeover).

### [B11] Dépendances vulnérables — **RAPPORTÉ** (pas de `fix --force`)
`npm audit` backend : **5 vulnérabilités** — 1 high (`sharp`), 1 moderate, 3 low. `sharp` = transitive (traitement d'image), risque runtime faible ; mise à jour ciblée recommandée (`npm audit fix` sans `--force`, tester). Aucune critical.

---

## Ordre d'application (Partie C)
1. ✅ Ce rapport (carte complète).
2. ✅ Correctifs sûrs appliqués : A1, A2, B7 (SMS/bureau), B8 (bureau `.or()`), B10.
3. ⏳ **En attente de validation humaine** : **F1, F2, F3, F4** (B2), **IDOR wallet** (B3), **SECURITY DEFINER/RLS** (B4), **SSRF audioUrl** (B6), durcissements JWT (B9). Ne PAS corriger avant feu vert.
4. Action serveur (ops) : `NODE_ENV=production` sur PM2 (linchpin A1/B10) ; brancher Sentry backend.
