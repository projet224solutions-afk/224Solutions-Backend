# CORRECTIONS BUGS BACKEND — RAPPORT
Date : 2026-06-21
Repo : 224Solutions-Backend

## Résumé
| # | Bug | Sévérité | Statut |
|---|-----|----------|--------|
| 1 | PayPal webhook sans signature + UPDATE sans WHERE | CRITIQUE | ✅ Corrigé |
| 2 | /api/migrations sans authentification | CRITIQUE | ✅ Déjà protégé + durci |
| 3 | media/upload faux succès | CRITIQUE | ✅ Corrigé (upload réel Storage) |
| 4 | JWT_SECRET vide / MFA_ENCRYPTION_KEY | ÉLEVÉ | ✅ Renforcé |
| 5 | Double import auth.routes.js | ÉLEVÉ | ✅ Corrigé |
| 6 | jobs/internal routes faux succès | ÉLEVÉ | ✅ Corrigé (enqueue réel / 501) |
| 7 | console.log en production | ÉLEVÉ | ⚠️ Partiel (fichiers visés OK) |
| 8 | multer mimetype côté client seulement | MODÉRÉ | ✅ Corrigé (magic bytes) |
| 9 | SMS silencieux | MODÉRÉ | ✅ Corrigé (sendSms réel) |
| 10 | @ts-ignore sur migrations | MODÉRÉ | ✅ Corrigé |

## Détails & écarts assumés (adaptations au vrai code)

### 1 — PayPal webhook (`src/routes/edge-functions/payments.routes.ts`)
- Ajout du helper `verifyPayPalWebhookSignature()` (API officielle PayPal `verify-webhook-signature`).
- Vérification de signature AVANT tout traitement ; rejet `401` si invalide.
- `order_id` validé (string non vide) — sinon `200` sans aucun UPDATE.
- UPDATE scopé `.eq("id", orderId).eq("status","pending")` (garde-fou).
- Client Supabase existant = `supabase` (conservé).
- **Vérifié en live** : sans config PayPal locale → `500` « non configuré » (fail-closed, **aucun UPDATE**) ; l'ancien `.eq("id", undefined)` qui passait TOUTES les commandes en payé est éliminé.

### 2 — migrations (`src/routes/migrations.ts`)
- ⚠️ La faille « sans auth » était **déjà fermée** : `router.use(authenticateInternal)` (clé API interne) protège déjà toutes les routes. **Vérifié live : POST sans token → 401.**
- Décision : NE PAS remplacer `authenticateInternal` par `verifyJWT+rôle` (ce serait latéral, voire plus faible pour des opérations d'ops). Conservé tel quel.
- Fait : `console.*` → `logger.*` (10 occurrences, emojis retirés), import `logger` ajouté.

### 3 + 8 — media (`src/routes/media.routes.js`)
- Upload RÉEL vers Supabase Storage (`supabaseAdmin.storage.from('media')`) + URL publique + nettoyage du fichier temp (`finally`).
- Vérification **magic bytes** (`file-type` v22, `fileTypeFromBuffer`) — refuse un fichier dont le contenu ≠ image autorisée (`400`).
- `/optimize` → `501` (mock Sharp retiré).
- ⚠️ **Action infra requise** : le bucket Storage `media` doit exister (sinon upload `500`).

### 4 — secrets (`src/config/env.ts`)
- `assertSecretsOnBoot()` renforcée : message JWT_SECRET clarifié + branche prod ; **erreur bloquante** en prod si `MFA_ENCRYPTION_KEY` (et tous fallbacks) absents.

### 5 + 10 — `src/server.ts`
- `authRoutesLegacy` (double import du même module) supprimé ; un seul montage `app.use('/auth', authRoutes)`.
- `@ts-ignore` retirés sur `migrationsRoutes` et l'import legacy auth.

### 6 — jobs/internal (`src/routes/jobs.routes.js`, `src/routes/internal.routes.js`)
- API réelle = `jobQueue.enqueue(name, data)` (pas `.add()`/`job.id`).
- `process-images` & `trigger-job` : `enqueue` réel **si `REDIS_URL` configuré**, sinon `501` honnête.
- `generate-reports`, `/:jobId/status`, `process-batch` : `501` (pas d'implémentation réelle → plus de faux `200`).

### 7 — console.log → logger
- ✅ `payments.routes.ts` (0 restant) + `migrations.ts` (0 restant) — fichiers visés par les corrections.
- ⚠️ **Reste ~68 `console.*` dans d'autres fichiers `src/routes/`** non visés par ce lot. Sweep global = tâche séparée (chaque fichier doit aussi importer `logger`).

### 9 — SMS (`src/routes/edge-functions/notifications.routes.ts`)
- Service réel = `sendSms(to, message)` → `{ok, error}` (Twilio backend → repli Edge `send-sms`).
- Route `/sms` : appelle `sendSms(phone_number, message_body)` ; `503` si échec, `200 {sent:true}` si OK. Plus de faux `queued:true`.

## Dépendance ajoutée
- `file-type` (v22) — vérification magic bytes des uploads.

## Variables d'env à définir en production
- `PAYPAL_CLIENT_ID`, `PAYPAL_CLIENT_SECRET`, `PAYPAL_WEBHOOK_ID` (ajoutées à `.env.example`)
- `MFA_ENCRYPTION_KEY` (≥32 chars, dédié)

## Validation
- Serveur (mode watch `tsx`) **rechargé sans erreur — healthz 200** après tous les changements.
- `POST /api/migrations/apply-type-agent` sans token → **401** ✅
- `POST /edge-functions/payments/paypal/webhook` (payload d'injection) → **500 fail-closed, aucun UPDATE** ✅
