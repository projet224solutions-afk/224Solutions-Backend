# RLS_AUDIT_REPORT — audit des policies `<col> = auth.uid()`

**Date** : 2026-07-25 · **Base** : production (uakkxaibujzxdiqzpnpr) · **Périmètre** : BLOC A du prompt « Ce qui manque ».

Mode de défaillance rappelé : ces identifiants sont des **UUID**, collision impossible → une policy cassée = **refus d'accès légitime silencieux**, jamais une fuite. Exception : une policy trop **large** (`USING(true)`) = exposition — traitée en priorité ci-dessous.

---

## 0. Conclusion en une ligne

La peur de « 40 fonctionnalités cassées » est **largement infondée** : dans la quasi-totalité des cas, la branche `<col> = auth.uid()` est **redondante** — la même policy (ou une policy sœur sur la table) porte déjà la **bonne** jointure (`is_vendor_or_agent(vendor_id)`, `vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid())`, `customer_belongs_to_auth_user(...)`). La fonctionnalité marche ; la branche fautive est du **code mort à nettoyer**.

**Deux vrais problèmes** :
1. 🔴 **`payment_schedules`** : policy `USING(true)` → tout utilisateur connecté lit TOUS les échéanciers de paiement. **Exposition financière — priorité absolue.**
2. 🟠 **`order_items`** (self-acheteur) : seule branche pour l'acheteur, cassée → notation produits bloquée. **Déjà corrigé** (policy `order_items_buyer_select`, appliquée en prod le 24/07 ; versionnée ici).

---

## 1. Fait structurel confirmé

| Colonne | Référence réelle | Vaut `auth.uid()` ? |
|---|---|---|
| `orders.customer_id`, `*.customer_id` (FK customers) | `customers.id` | ❌ non → jointure via `customers.user_id` |
| `*.vendor_id` (FK vendors) | `vendors.id` | ❌ non → jointure via `vendors.user_id` |
| `*.client_id`, `*.vendor_id` (FK profiles) | `profiles.id` | ✅ **oui** (48/48 `profiles.id ∈ auth.users`) |
| `customer_id`/`client_id` sans FK, valeurs = auth | (dénormalisé) | ✅ oui (au cas par cas) |

`profiles.id = auth.uid()` → toute policy comparant une colonne **FK=profiles.id** à `auth.uid()` est **correcte**.

---

## 2. Tableau de synthèse (60 policies à comparaison directe)

Verdicts : **OK** (colonne = auth.uid) · **REDONDANTE** (branche morte, mais la fonctionnalité marche via une autre branche/policy) · **CASSÉE** (seul chemin, fonctionnalité réellement bloquée) · **TROP LARGE** (exposition) · **À VÉRIFIER** (table vide / ref indéterminée).

### 🔴 TROP LARGE (priorité)
| Table | Policy | Détail | Fonctionnalité |
|---|---|---|---|
| `payment_schedules` | `Vendors can view their payment schedules` | `USING (true)`, SELECT, `authenticated` | **Tout connecté lit tous les échéanciers** (montants, dates, clients). Fix : migration `…payment_schedules_rls_tighten`. |

### 🟠 CASSÉE (fonctionnalité réellement bloquée)
| Table | Policy | Colonne | Contenu réel | État |
|---|---|---|---|---|
| `order_items` | `order_items_party_all` (branche acheteur) | `orders.customer_id` (jointe) | `customers.id` | **Corrigé** via `order_items_buyer_select` (SELECT, `customer_belongs_to_auth_user`). Versionné. |

### 🧹 REDONDANTE (branche `<col> = auth.uid()` morte — la fonctionnalité marche via une branche correcte présente)
| Table | Policy | Colonne (FK) | Branche correcte qui couvre | Verdict |
|---|---|---|---|---|
| `inventory_history` (977 lignes) | `inventory_history_owner_select` | `vendor_id` (vendors.id) | `user_id = auth.uid()` + `vendor_id IN (vendors WHERE user_id=auth.uid())` | marche ; nettoyer la branche `vendor_id = auth.uid()` |
| `vendor_ai_control` (3) | `..._owner_select` | `vendor_id` (vendors.id) | `is_vendor_or_agent(vendor_id)` | marche ; nettoyer |
| `vendor_ai_decisions` (1) | `..._owner_select` | `vendor_id` (vendors.id) | `is_vendor_or_agent(vendor_id)` | marche ; nettoyer |
| `vendor_ai_documents` (2) | `..._owner_select` | `vendor_id` (vendors.id) | `is_vendor_or_agent(vendor_id)` | marche ; nettoyer |
| `vendor_ai_execution_logs` (7) | `..._owner_select` | `vendor_id` (vendors.id) | `is_vendor_or_agent(vendor_id)` | marche ; nettoyer |
| `vendor_ai_marketing_campaigns` (1) | `..._owner_select` | `vendor_id` (vendors.id) | `is_vendor_or_agent(vendor_id)` | marche ; nettoyer |
| `vendor_review_sentiment_analysis` (0) | `..._owner_select` | `vendor_id` (vendors.id) | `is_vendor_or_agent(vendor_id)` | marche ; nettoyer |
| `vendor_stock_ai_alerts` (0) | `..._owner_select` | `vendor_id` (vendors.id) | `is_vendor_or_agent(vendor_id)` | marche ; nettoyer |
| `shipments` (0) | `shipments_vendor_select` | `vendor_id` (vendors.id) | `is_vendor_or_agent(vendor_id)` | marche ; nettoyer |
| `favorites` (0) | `customers_own_favorites` | `customer_id` (customers.id) | policy sœur `Users can manage their favorites` (customers WHERE user_id=auth.uid()) | marche ; supprimer la doublon cassée |
| `customer_credits` (0) | `users_own_customer_credits` (branche customer) | `customer_id` (customers.id) | branche vendeur + `Vendors manage customer credits` + `_agent_access` | accès vendeur/agent marche |
| `interactions` (0) | `users_own_interactions` (branche customer) | `customer_id` (customers.id) | branche vendeur + `interactions_vendor_agent_manage` | accès vendeur marche |
| `international_shipments` | `users_own_international_shipments` (branche customer, jointe orders) | `orders.customer_id` | `transitaire_id = auth.uid()` + admin | accès transitaire/admin marche |
| `payment_schedules` | `users_own_payment_schedules` (branche customer, jointe orders) | `orders.customer_id` | branche vendeur (vendors WHERE user_id=auth.uid) | accès vendeur marche |

### ✅ OK (colonne = auth.uid, aucune correction)
`deliveries.client_id` (1/1), `service_reviews.client_id` (2/2), `vendor_expenses.vendor_id` (12/12), `vendor_ratings.customer_id` (33/33), `vendor_certifications.vendor_id` (1/1, cas connu `user_id`), `vendor_notifications.vendor_id` (profiles.id, 487/487), `vendor_kyc.vendor_id` (profiles.id), `vendor_trust_score.vendor_id` (profiles.id), `suspicious_activities.vendor_id` (profiles.id), `payment_links.client_id` (profiles.id + branche `owner_user_id`).

### ⚠️ À VÉRIFIER (table vide ou ref indéterminée — décision manuelle Thierno)
- `reviews.customers_own_reviews` (`customer_id = auth.uid()`, ALL) : la seule branche de gestion client, cassée. **Mais** les avis produit passent par `product_reviews` (`user_id`, correct) — vérifier si la table `reviews` est encore utilisée côté client avant de corriger.
- `taxi_trips.customer_id` : **MIXTE 55/64** (données incohérentes) — certains `customer_id` = auth.uid, d'autres non. À investiguer (migration de données ?).
- `pharmacy_orders.client_id` (2 lignes) : ni auth, ni customers.id — ref inconnue. Déterminer la table cible.
- `artisan_*`, `proximity_bookings`, `service_bookings`, `prescriptions`, `medication_reminders`, `disputes`, `delivery_driver_ratings`, `dropship_china_*` : **tables vides** → verdict impossible empiriquement ; classer d'après la FK au peuplement.

---

## 3. Migrations créées (NON appliquées — attente validation Thierno, table par table)

| Fichier | Objet | Effet | Risque |
|---|---|---|---|
| `…_order_items_rls_buyer_branch.sql` | **A.2** — versionner l'état RÉEL des 3 policies de `order_items` (dont `order_items_buyer_select`) | reproduit fidèlement la prod (idempotent) | nul (reflète l'existant) |
| `…_payment_schedules_rls_tighten.sql` | **PRIORITÉ** — retirer la policy `USING(true)` ; l'accès légitime reste via `users_own_payment_schedules` | **resserre** (ferme la fuite) | à valider : vérifier qu'aucun écran vendeur ne dépendait de la lecture globale |
| `…_vendor_ai_rls_cleanup.sql` (×7) + `inventory_history` + `shipments` + `favorites` | **A.4** — remplacer la branche morte `<col> = auth.uid()` par la bonne jointure (ou retirer la doublon) | **aucun changement d'accès** (nettoyage) | nul |

> Convention respectée : `DROP POLICY IF EXISTS` puis `CREATE POLICY`, un fichier par table, commentaire de cause racine, **sans élargir l'accès**.

---

## 4. Appliqué vs en attente

- **Appliqué en prod** (avant cet audit, 24/07) : `order_items_buyer_select` (le seul correctif fonctionnel réel). Divergence repo↔prod : **cette policy n'était pas versionnée** → corrigé par la migration A.2 ci-dessus.
- **En attente de validation Thierno** : la migration `payment_schedules` (priorité) et les migrations de nettoyage. **Rien d'autre appliqué.**

## 5. Recommandation de priorité

1. **Valider + appliquer** `payment_schedules_rls_tighten` (fuite financière active).
2. **Pousser** la migration `order_items` (réconcilier repo↔prod).
3. Nettoyage des branches mortes : sans urgence (fonctionnalités déjà OK).
4. Trancher les `À VÉRIFIER` (`reviews`, `taxi_trips`, `pharmacy_orders`) au cas par cas.
