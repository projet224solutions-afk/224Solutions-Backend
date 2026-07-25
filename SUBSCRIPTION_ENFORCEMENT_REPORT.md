# Rapport — Restriction immédiate à l'expiration d'abonnement

**Décision produit (Thierno)** : à l'expiration, le vendeur perd **immédiatement** l'accès. Ses
produits disparaissent du marketplace / des catégories / du POS. Pas de période de grâce.

**Statut** : code + migration **livrés, non appliqués/déployés** (en attente de validation).
Vert : backend `tsc`=0, frontend `tsc`=0, `vite build`=0, `check:i18n`=25 langues, `vitest`=245/245,
**dry-run de la migration en prod (`BEGIN … ROLLBACK`) sans erreur** (syntaxe, refs colonnes, corps
de fonctions, triggers validés contre le schéma réel, rien persisté).

---

## 1. Ce qui a été construit

### 1.1 Source de vérité serveur — `has_active_feature(user, feature)`
Migration `backend/supabase/migrations/20260725120000_subscription_feature_gate.sql`.
- Table `plan_features(plan_id, feature_key)` **seedée à l'identique de la source frontend actuelle**
  (`src/hooks/useSubscriptionFeatures.ts` → `PLAN_FEATURES`), 5 plans vendeur (138 lignes).
- Fonction `has_active_feature` `SECURITY DEFINER` (`REVOKE PUBLIC` + `GRANT authenticated, service_role`).
  Vraie si un abonnement **actif/trialing non expiré** accorde la fonctionnalité **OU** si c'est une
  fonctionnalité du **socle free** (garantit `products_basic`/`orders_simple` même sans ligne
  d'abonnement — un vendeur non abonné n'est jamais bloqué sur le minimum).

### 1.2 Réversibilité — `products.hidden_by_subscription`
Colonne `boolean NOT NULL DEFAULT false` + index partiel. Marqueur **distinct** de la désactivation
manuelle : seul un produit masqué par l'expiration revient au renouvellement ; un produit que le
vendeur avait désactivé lui-même (`is_active=false`, `hidden_by_subscription=false`) **reste désactivé**.

### 1.3 Masquage + réactivation = **2 triggers atomiques sur `subscriptions`**
> **Écart assumé vs le prompt (§4.2/4.3)** : plutôt que d'étendre le job Node `expire-check` et de
> modifier la RPC d'achat, la logique vit dans des **triggers**. C'est **plus robuste** : atomique
> dans la transaction qui change le statut (le job d'expiration OU la RPC d'achat), **idempotent**,
> **non contournable**, et **sans modifier la RPC d'achat atomique** (respecte l'interdit #5 tout en
> satisfaisant « dans la même transaction » du §4.3). Le job `expire-check` reste inchangé : c'est lui
> qui pose `status='expired'`, ce qui **déclenche** le trigger de masquage.

- `trg_hide_products_on_expiry` (AFTER UPDATE) : quand un abonnement **payant** passe à `expired`,
  masque **uniquement** les produits actuellement `is_active=true` (`is_active=false` +
  `hidden_by_subscription=true`) et notifie le vendeur (message clair + `metadata`).
- `trg_reactivate_products_on_renewal` (AFTER INSERT/UPDATE) : quand un abonnement **payant** devient
  actif, réactive les produits `hidden_by_subscription=true`, **quota-aware** (plan illimité = tout ;
  plan fini = jusqu'au quota restant, **les plus récents d'abord**) et notifie s'il en reste masqués.

### 1.4 RLS `payment_links` (priorité)
La création de lien de paiement se fait par **insert Supabase direct** côté client
(`usePaymentLinks.ts`) — **il n'existe aucune route backend de création**. Le vrai rempart est donc la
**RLS**, pas le middleware. La policy propriétaire `« Owners can manage their payment links »` est
reflétée fidèlement (USING/CHECK = `owner_user_id = auth.uid()`) et la condition
`has_active_feature(auth.uid(),'payment_links')` est ajoutée **uniquement au `WITH CHECK`** → gate
**INSERT + UPDATE** (la ligne écrite), **sans** toucher `SELECT`/`DELETE` (USING) : un vendeur expiré
**voit** et peut **annuler/supprimer** ses liens, mais n'en **crée/édite** plus.
> Conséquence : un `curl` direct (PostgREST) sans abonnement est bloqué en **403 RLS** (et non 402).
> Le 402 est réservé aux routes **backend**. Les deux « bloquent » ; le canal diffère.

### 1.5 Middleware backend — `requireFeature('<clé>')`
`backend/src/middlewares/subscriptionFeature.middleware.ts`. Refus → **402** `{ success:false,
error:'subscription_required', feature }`. **FAIL-CLOSED** (RPC en échec → refus). Cache Redis 60 s des
résultats **positifs uniquement** (un refus n'est jamais caché → un vendeur qui vient de renouveler
n'est pas bloqué). Appliqué **uniquement** aux routes de création/mutation, jamais aux lectures.

---

## 2. Fonctionnalités désormais protégées **côté serveur**

| Fonctionnalité | Mécanisme serveur | Emplacement |
|---|---|---|
| `payment_links` (création/édition) | **RLS `WITH CHECK`** + `has_active_feature` | migration §4 |
| `copilot_ai` | `requireFeature` (402) | `copilot.routes.ts` `POST /`, `POST /stream` |
| `pos_system` | `requireFeature` (402) | `pos.routes.ts` `POST /order` |
| `inventory_management` | `requireFeature` (402) | `inventory.routes.ts` `POST /adjust` |
| **Visibilité produit** (marketplace/catégories/POS) | trigger `is_active=false` à l'expiration | migration §5 |

### Routes modifiées
- `backend/src/routes/copilot.routes.ts` — `requireFeature('copilot_ai')` sur `/` et `/stream`.
- `backend/src/routes/pos.routes.ts` — `requireFeature('pos_system')` sur `/order`.
- `backend/src/routes/inventory.routes.ts` — `requireFeature('inventory_management')` sur `/adjust`.
- `backend/src/services/` — (aucune) ; `expire-check` **inchangé** (triggers).
- Frontend : `src/services/backendApi.ts` (interception 402 → event global), `App.tsx` (montage du
  listener), `src/components/subscription/SubscriptionRequiredListener.tsx` (nouveau, redirige vers
  l'écran d'abonnement), `src/components/vendor/SubscriptionExpiryBanner.tsx` (état post-expiration
  clair « vos produits ne sont plus visibles » — la fausse promesse « produits visibles X jours » de
  l'ancienne période de grâce a été retirée), i18n (4 clés × 25 langues).

---

## 3. Constat sur `subscription_weight` (§4.4)

**Aucune action requise à l'expiration.** Le poids d'abonnement du classement marketplace est
**lu EN DIRECT** : `backend/src/services/marketplaceVisibility.service.ts` `getVendorPlanMap()` fait une
jointure temps réel `subscriptions` (statut `active`/`trialing`) → `plans` **au moment de chaque
classement**. **Aucune colonne dénormalisée** (`subscription_tier`/`plan_rank`) sur `products` ou
`vendors`. Donc dès qu'un abonnement expire, le classement retombe seul sur le score `free`. Et surtout,
la visibilité publique ne dépend pas du poids : la requête marketplace filtre `is_active=true`
(`useMarketplaceUniversal.ts`) — c'est le masquage `is_active=false` (trigger) qui retire réellement les
produits, le poids n'agit que sur **l'ordre**.

---

## 4. Les 8 vérifications

Le code/migration satisfont chaque point **par construction** ; les mentions « live » nécessitent la
migration appliquée pour un test bout en bout.

1. **Vendeur expiré → produits hors marketplace/catégories** : ✅ par conception — trigger
   `is_active=false` ; requêtes publiques filtrent `is_active=true` (+ RLS `anon_view_active_products`
   = `is_active=true`). À confirmer live.
2. **Le même vendeur voit toujours ses produits (dashboard)** : ✅ — la RLS `« Vendors can manage own
   products »` (USING `is_vendor_or_agent(vendor_id)`) n'est pas touchée ; le dashboard ne filtre pas
   `is_active`. Lecture préservée.
3. **Création de lien via curl+JWT → bloquée** : ✅ par conception — RLS `WITH CHECK` +
   `has_active_feature` → **403 RLS** (canal direct PostgREST). À confirmer live.
4. **Renouvellement → seuls les `hidden_by_subscription=true` reviennent** : ✅ — trigger de
   réactivation filtre `WHERE hidden_by_subscription = true`. À confirmer live.
5. **Produit désactivé manuellement avant expiration → reste désactivé** : ✅ — le masquage ne touche
   que `is_active=true` (donc ne marque jamais un produit déjà désactivé) ; la réactivation ne touche
   que `hidden_by_subscription=true`. Le produit manuel (`is_active=false`, `hidden=false`) est ignoré
   des deux côtés.
6. **Plan gratuit → `products_basic` et `orders_simple` OK** : ✅ — clause « socle free » dans
   `has_active_feature` (vraie inconditionnellement pour les features du plan free).
7. **RPC `has_active_feature` en échec → accès refusé** : ✅ — middleware **fail-closed** (refus 402
   sur erreur/exception RPC).
8. **Job relancé deux fois → aucun effet double** : ✅ — masquage conditionné à une **transition**
   `→ expired` (`OLD.status IS DISTINCT FROM 'expired'`) et ne cible que `is_active=true` ; 2ᵉ passage
   = les subs sont déjà `expired` (exclues du `WHERE` du job) et 0 produit actif à masquer.
   Dry-run confirme l'application propre + idempotence structurelle.

---

## 5. Fonctionnalités encore protégées **uniquement côté frontend** (`<ProtectedRoute>`)

Server-truth posée pour `payment_links`, `pos_system`, `inventory_management`, `copilot_ai` + la
visibilité produit. **Restent gardées côté frontend seulement** (à durcir progressivement, même
recette) : `affiliate_program`, `analytics_basic/advanced/realtime`, `communication_hub`, `contracts`,
`crm_basic/advanced`, `data_export`, `debt_management`, `delivery_tracking`, `expenses`,
`marketing_promotions`, `multi_warehouse`, `offline_mode`, `orders_detailed`, `payments`,
`prospect_management`, `quotes_invoices`, `sales_agents`, `supplier_management`, `products_unlimited`,
`gemini_ai`, `multi_user`, `advanced_integrations`, `stock_alerts`, `featured_products`, etc.
Recommandation : pour les tables écrites en direct par le client (comme `payment_links`), privilégier
la **RLS `WITH CHECK` + `has_active_feature`** (non contournable) ; pour les mutations passant par une
route backend, le **middleware `requireFeature`**.

---

## 6. ⚠️ ORDRE DE DÉPLOIEMENT (critique)

Le middleware est **fail-closed** : si `has_active_feature` n'existe pas encore, il refuse **tout**
(402) — y compris pour les vendeurs payants → POS/copilote/inventaire cassés pour tous.

**Séquence obligatoire :**
1. **Appliquer la migration `20260725120000`** (crée `has_active_feature`, `plan_features`, la colonne
   et les triggers) — après ta validation table par table.
2. **Ensuite seulement**, déployer le backend (gardes `requireFeature`) et le frontend (402 + bannière).

Ne jamais déployer le backend avant la migration. La migration seule (sans le backend) est déjà sûre
et active immédiatement le masquage/réactivation (triggers) + la RLS `payment_links`.

---

## 7. Écarts assumés vs le prompt (récap)
1. **Masquage/réactivation par triggers** (et non extension du job + modif RPC) → atomique, idempotent,
   non contournable, respecte l'interdit #5. Le job reste inchangé et déclenche le trigger.
2. **`payment_links` gardé par RLS (403)** et non middleware 402 → la création est un insert Supabase
   **direct** côté client, aucune route backend à garder.
3. **`has_active_feature` avec clause « socle free »** (superset de la version du prompt) → garantit le
   minimum même sans ligne d'abonnement.
