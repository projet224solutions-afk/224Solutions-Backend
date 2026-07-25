# Rapport de déploiement — réconciliation état réel

**Date de vérification : 2026-07-25.** Toutes les mesures ci-dessous sont issues de requêtes
**réelles sur la base de production** (Management API) et des dépôts Git.

> ⚠️ **Écart avec la prémisse du prompt.** Le prompt indiquait « 8 migrations, AUCUNE appliquée ».
> La vérification en production **contredit** cette prémisse : les 6 migrations nommées sont **DÉJÀ
> APPLIQUÉES** (certaines lors de sessions antérieures, d'autres plus tôt dans la session courante),
> le backend est **déjà déployé**, et la CSP est **déjà en mode appliqué**. Conformément à la règle
> « si ce que je constate contredit la description, le signaler plutôt que d'exécuter », **je n'ai
> rien réappliqué ni redéployé à l'aveugle**. Ce rapport documente l'état réel et isole la **seule
> décision commerciale** restante.

## Backups (prérequis)
walg activé, **7 sauvegardes**, la plus récente **COMPLETED le 2026-07-24** (quotidiennes). PITR non
activé. ✅ Un backup récent existe.

## BLOC 2 — État réel des 6 migrations

| Ordre | Migration | État | Preuve (prod, 2026-07-25) |
|---|---|---|---|
| Ét.1 | `payment_schedules_rls_tighten` 🔴 | **APPLIQUÉ** | policies = `users_own_payment_schedules` seule ; la policy `USING(true)` « Vendors can view their payment schedules » est **absente**. Fuite fermée. |
| Ét.2 | `order_items_rls_buyer_branch` | **APPLIQUÉ** | 3 policies présentes (`order_items_buyer_select`, `order_items_party_all`, `vendors_own_order_items`). |
| Ét.3a | `vendors_country_code_normalize` | **APPLIQUÉ** | colonne `country_code` présente, **0 NULL** (GN=15, SN=1, FR=1). |
| Ét.3b | `country_marketplace_config` | **APPLIQUÉ** | table présente, seedée tous pays. |
| Ét.3c | `marketplace_certified_suppliers_v2` | **APPLIQUÉ** | signature 5 args ; Guinée = GN = NULL = **1** (cohérent). Voir `COUNTRY_SUPPLIERS_BUILD_REPORT.md`. |
| Ét.4 | `subscription_feature_gate` ⚠️ | **APPLIQUÉ** | `plan_features` + `has_active_feature` + colonne `hidden_by_subscription` + **2 triggers**. Socle free = `products_basic, orders_simple, ratings, support_basic, wallet_basic` (contient bien products_basic + orders_simple). `has_active_feature` : anon/PUBLIC révoqués. |

**Ordre critique respecté** : la migration `subscription_feature_gate` a été appliquée **AVANT** le
déploiement du backend `requireFeature` (dans la session courante), donc **aucun fail-closed** n'a
frappé les vendeurs payants. Vérification `has_active_feature('<premium>','pos_system')` = **true**.

## Ét.5 — Déploiement
- **Backend** poussé sur `main` (`17985b6`) → VPS. `healthz` = **200**. Inclut `requireFeature`,
  errorHandler générique, `trust proxy` borné, rate-limit.
- **Frontend** poussé sur `main` (`2fb20c0c1`) → Vercel. Interception 402 + bannière.

### ⚠️ Actions OPS restantes (variables VPS — hors code, non vérifiables à distance)
| Item | État observé | Action |
|---|---|---|
| `TRUST_PROXY_HOPS` | code applique `Number(TRUST_PROXY_HOPS) \|\| 1` (défaut sûr=1) ; valeur de la var VPS **non vérifiable à distance** | poser explicitement + valider `curl -H "X-Forwarded-For: 1.2.3.4" …/healthz` (log = IP réelle) |
| `RATE_LIMIT_MAX_REQUESTS` | en-tête live = **6000** (surcharge VPS ; mon défaut code 1200 est inerte) | passer la var VPS à **1200** puis reload |
| `NODE_ENV` | non vérifiable à distance ; le fix errorHandler protège même si absent | poser `NODE_ENV=production` |

## Ét.6 — CSP
**Déjà en mode appliqué** en prod (header `Content-Security-Policy`, plus de Report-Only ; `connect-src`
corrigé avec `224solution.net`, `media-src`, spline, `*.stripe.com`/`*.paypal.com`). Vérifié : **0
violation** au chargement sur 8 routes publiques (test Chromium headless). **RESTE** : un clic humain
sur les parcours interactifs (checkout Stripe/PayPal, appel Agora, carte Mapbox) — non déclenchables
sans session. Rollback = repasser `Content-Security-Policy-Report-Only` dans `vercel.json`.

---

## 🔴 LA SEULE DÉCISION EN ATTENTE — masquage rétroactif

Le trigger `subscription_feature_gate` masque les produits **à la transition** actif→expiré. Les
vendeurs **déjà expirés AVANT** l'existence du trigger n'ont donc **pas** été masqués rétroactivement.

**Mesure prod (2026-07-25)** :
- **6 vendeurs** déjà `expired` ont **59 produits encore visibles** dans le marketplace.
- **0 produit** actuellement masqué par abonnement (l'application de la migration n'a **rien** masqué
  en masse — elle était sûre).

**Décision commerciale (pas technique) — pour Thierno :** faut-il lancer un **backfill unique** qui
masque ces 59 produits pour honorer la règle « à l'expiration, les produits disparaissent » ? Si oui,
6 vendeurs perdent leur visibilité d'un coup — il voudra peut-être les prévenir avant. **Je n'exécute
rien tant que ce n'est pas validé.** (Le backfill serait : `UPDATE products SET is_active=false,
hidden_by_subscription=true WHERE is_active=true AND vendor_id IN (vendeurs expirés)` — atomique,
réversible au renouvellement par le trigger existant.)

---

## BLOC 3 — Fiches des policies « À trancher » (aucune correction sans validation)

> Précision : le `RLS_AUDIT_REPORT.md` ne contient **qu'une seule** policy `CASSÉE` (`order_items`),
> et elle est **déjà corrigée** (`order_items_buyer_select`, appliquée). Les items ci-dessous sont les
> **À VÉRIFIER** — les seuls qui restent à décider.

| Table / policy | Fonctionnalité potentiellement affectée | Ampleur (prod) | Depuis | Recommandation |
|---|---|---|---|---|
| `reviews.customers_own_reviews` (`customer_id=auth.uid`, ALL) | gestion d'avis côté client | **table VIDE (0 ligne)** | — | **Non urgent** : rien de réellement bloqué. Les avis produit passent par `product_reviews` (correct). Reclasser au premier peuplement, ou déprécier `reviews` si inutilisée. |
| `taxi_trips.customer_id` | un passager voit ses propres trajets | **9 trajets sur 64** ont un `customer_id` incohérent (ni `auth.uid` ni `customers.id`) ; 55/64 OK | données legacy | **Migration de DONNÉES** (pas de policy) : identifier l'origine des 9 `customer_id` orphelins et les remapper. Faible ampleur. |
| `pharmacy_orders.client_id` (2 lignes) | un client voit sa commande pharmacie | **2 lignes, `client_id` = NULL** | — | **Non urgent** : aucune donnée client réelle à protéger. Déterminer la table cible de `client_id` avant tout usage réel. |
| Tables VIDES : `artisan_*`, `proximity_bookings`, `service_bookings`, `prescriptions`, `medication_reminders`, `disputes`, `delivery_driver_ratings`, `dropship_china_*` | divers | **0 ligne** | — | **Ne pas deviner.** Verdict RLS impossible sans données. Créer une tâche de reclassement **au premier peuplement** de chaque table. |

Aucune de ces policies n'est corrigée dans ce lot (respect de l'interdit « ne pas corriger sans validation »).

---

## Synthèse des statuts

| Élément | Statut |
|---|---|
| 6 migrations nommées | **APPLIQUÉ** (vérifié) |
| Backend + Frontend | **DÉPLOYÉ** (healthz 200, CSP appliquée) |
| Masquage rétroactif (6 vendeurs / 59 produits) | **EN ATTENTE VALIDATION Thierno** |
| Ops VPS (TRUST_PROXY_HOPS, RATE_LIMIT→1200, NODE_ENV) | **EN ATTENTE** (action serveur) |
| CSP parcours interactifs | **EN ATTENTE** (clic humain) |
| BLOC 3 (reviews/taxi_trips/pharmacy_orders/vides) | **EN ATTENTE DÉCISION** (fiches ci-dessus) |
| Fuites/expositions | **FERMÉES** (payment_schedules, order_items) |
