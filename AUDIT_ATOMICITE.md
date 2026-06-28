# Audit de couverture atomique — 224Solutions Backend

Date : 2026-06-27 · Méthode : inventaire RPC + détection écritures financières multiples sans transaction.

## Contexte
Système **très mûr** : 1197 migrations, **~64 RPC atomiques** (`execute_atomic_*`, `process_*`,
`purchase_*_subscription_atomic`, `refund_order_escrow`, `release_escrow_funds`, etc.) couvrant
dépôts, retraits, transferts (+FX), abonnements vendor/service/driver, escrow, paiements artisans,
loyers, commandes, cartes, retours. **Ces RPC sont INTOUCHABLES.**

---

## 🔴 Flux NON atomiques / INCOMPLETS (à corriger)

### 1. Routes edge escrow sur table `escrows` (legacy/vide) — no-op silencieux
`src/routes/edge-functions/payments.routes.ts`
- `escrow-auto-release` (~L968), `escrow-refund` (~L1000), `escrow-dispute` (~L988)
- Font un `escrows.update({status})` **brut**, sans mouvement d'argent.
- **La table `escrows` n'est JAMAIS alimentée** (0 INSERT dans tout le code/migrations) → ces routes
  opèrent sur une table vide = **no-op silencieux**.
- **Appelées par le frontend** : `EscrowDashboard.tsx`, `EscrowService.ts`, `escrow224Service.ts`
  (`supabase.functions.invoke('escrow-refund'|'escrow-dispute')`).
- **Risque** : un admin clique « Rembourser », reçoit `success`, mais **rien n'est remboursé** (ni la
  table live `escrow_transactions`, ni le wallet). Faux sentiment de remboursement.
- **Correctif proposé** : router ces handlers vers les RPC atomiques existantes
  (`refund_order_escrow` / `release_escrow_funds` / `auto_release_escrows` sur `escrow_transactions`),
  OU migrer les appelants frontend vers `/api/admin/escrow/:id/refund` (déjà correct), OU supprimer
  si confirmé mort. **NE PAS créer de nouvelle RPC** (elles existent).

### 2. Refund de commande edge = stub admis
`src/routes/edge-functions/orders.routes.ts:587-593`
- Commentaire explicite : `// Refund logic would be implemented here // For now, just update escrow status`
- Marque `escrow_transactions.status='refunded'` **sans** rembourser le wallet de l'acheteur.
- **Correctif proposé** : appeler `refund_order_escrow` / `process_order_return_refund` (RPC atomiques
  existantes) au lieu de l'UPDATE brut.

---

## 🟠 Flux à durcir (atomiques/partiels mais fragiles)

### 3. Webhook Stripe refund — UPDATE statut escrow brut
`src/routes/webhooks.routes.ts:300-304`
- Restock via `increment_product_stock` (RPC, OK) **puis** `escrow_transactions.update({status:'refunded'})` brut.
- Pour un paiement **carte**, le remboursement réel est côté Stripe → l'UPDATE de statut peut suffire.
  À **confirmer** : si l'escrow détenait des fonds **wallet internes**, il faut `refund_order_escrow`.
- **Action** : confirmer le chemin de l'argent ; sinon passer par la RPC atomique.

### 4. Création wallet agent = 2 inserts séparés
`src/routes/agents.routes.ts:198 & 210`
- `wallets.insert` puis `agent_wallets.insert` (balance 0). Pas d'argent en mouvement, mais **état
  partiel** possible si le 2ᵉ échoue (wallet sans agent_wallet).
- **Mineur** (création, solde 0). Option : envelopper dans une petite RPC `create_agent_wallets` ou
  accepter (faible enjeu). À trancher.

---

## ✅ Flux DÉJÀ corrects — NE PAS TOUCHER

- **64 RPC atomiques** existantes (cf. inventaire) : dépôts/retraits/transferts/abonnements/escrow/etc.
- `vendors.routes.ts` changement de devise → `change_user_currency_atomic` (+ fallback documenté).
- `admin.routes.ts` escrow refund/dispute → `refund_order_escrow` + `verifyJWT` + `requireRole(PDG_ROLES)`.
- `vendorAffiliate.routes.ts` → commissions payées/annulées via `confirm_affiliate_commissions` /
  `cancel_affiliate_commissions` (RPC) ; l'insert commission est unique (status pending).
- `manual-credit-seller` → `credit_wallet` (RPC unique).
- **Frontend** : **aucune écriture financière directe** (wallets/transactions/escrows) — tout passe par
  backend/RPC. ✅
- Stubs no-op (`freight-payment`, `service-payment`, `wallet-operations`…) : sans effet, hors périmètre.

---

## Recommandation
Corriger **uniquement** #1 et #2 (vrais trous : escrow refund/release qui ne bougent pas l'argent,
câblés au frontend), en **réutilisant** les RPC atomiques existantes. Confirmer #3. Décider #4 (mineur).
Aucune RPC atomique existante à modifier ou dupliquer.
