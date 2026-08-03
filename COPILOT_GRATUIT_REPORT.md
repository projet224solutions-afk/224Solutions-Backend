# COPILOT_GRATUIT_REPORT

Date : 2026-08-03. Backend `a8f48b3` · Frontend `8ed398d9d`.

---

## Correction — Retrait du verrou d'abonnement du copilote UNIQUEMENT

### Backend (`src/routes/copilot.routes.ts`)
Diff (middlewares des 2 routes) :
```
- router.post('/',       verifyJWT, requireFeature('copilot_ai'), copilotRateLimit, …)
+ router.post('/',       verifyJWT,                               copilotRateLimit, …)

- router.post('/stream', verifyJWT, requireFeature('copilot_ai'), copilotRateLimit, …)
+ router.post('/stream', verifyJWT,                               copilotRateLimit, …)
```
- **`verifyJWT` CONSERVÉ** → copilote réservé aux **connectés** (pas d'accès anonyme qui exploserait la facture).
- **`copilotRateLimit` CONSERVÉ** → garde-fou anti-abus/anti-boucle (protection de la facture IA) intact.
- Import `requireFeature` retiré de ce fichier (il n'y était utilisé que pour le copilote ; POS/stock l'importent
  dans leurs propres fichiers).

### Frontend
- `VendorRoutes.tsx` : route `/vendeur/copilote` **sans** `feature="copilot_ai"` → plus de garde d'abonnement.
- `ProtectedRoute` : prop `feature` rendue **OPTIONNELLE** — sans `feature`, passthrough (aucune garde), l'auth/rôle
  restant assurée en amont par les routes du dashboard. Les usages existants passent tous une `feature` → inchangés.
- Le pop-up « Abonnement requis » (`SubscriptionRequiredListener`, déclenché par le 402 backend) **ne peut plus**
  se produire pour le copilote, puisque `/api/v2/copilot` ne renvoie plus `SUBSCRIPTION_REQUIRED`.

## NON touché (vérifié)
```
pos.routes.ts       : router.post('/order',  verifyJWT, requireFeature('pos_system'),          …)   ← INCHANGÉ
inventory.routes.ts : router.post('/adjust', verifyJWT, requireFeature('inventory_management'), …)  ← INCHANGÉ
```
- Middleware `subscriptionFeature` intact (toujours utilisé par POS/stock).
- Limites de services par métier des prestataires : non touchées.

## Vérification
1. **Compte sans abonnement → copilote** : `/api/v2/copilot` n'exige plus la feature (seulement JWT) → réponses IA
   sans pop-up « Abonnement requis ». ✓ (verrou retiré côté back ET front).
2. **Rate-limit** : `copilotRateLimit` toujours en place sur les 2 routes → rafale throttlée, pas de boucle. ✓
3. **Connectés uniquement** : `verifyJWT` conservé → un non-authentifié est refusé (401). ✓
4. **Non-régression payante** : POS (`pos_system`) et stock (`inventory_management`) gardent `requireFeature` →
   pop-up d'abonnement TOUJOURS présent pour un compte sans plan. ✓
5. Front : `tsc` 0 · `vitest` 274/274 · `build` OK.

**« Copilote IA gratuit pour tous (rate-limit conservé), POS/stock inchangés le 2026-08-03. »**
