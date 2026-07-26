# Reste technique — rapport de diagnostic

**Date : 2026-07-26.** Cinq blocs, aucun bloquant. Diagnostic uniquement — **aucune correction
appliquée** (conformément aux interdits). Chaque point non corrigé précise ce qui attend une décision.

---

## BLOC 1 — Réglages serveur : ACTIFS ✅ (vérifié, rien forcé)

Vérifié en SSH sur le VPS (`15.188.246.26`) + HTTPS, après le dernier déploiement :

| Vérification | Résultat |
|---|---|
| `.env` : `NODE_ENV` | **`production`** ✅ |
| `.env` : `RATE_LIMIT_MAX_REQUESTS` | **`1200`** ✅ (ni 6000 ni 10000) ; `RATE_LIMIT_WINDOW_MS=60000` |
| `.env` : `TRUST_PROXY_HOPS` | **`1`** ✅ |
| Process réel (`/api/version`) | `environment:"production"` ✅ (le filet de rollback n'a rien retiré) |
| En-tête `RateLimit-Limit` | `1200` ✅ |
| **Header forgé** `X-Forwarded-For: 1.2.3.4` via nginx | l'app logge l'IP réelle **`127.0.0.1`**, **0 occurrence de 1.2.3.4** ✅ |
| Port 3001 | **1 seul listener** ✅ (pas d'orphelin) |
| Restarts PM2 | **0**, `online` ✅ |

**Rien à forcer.** Le déploiement applique bien les trois réglages ; leur prise d'effet est constatée.
Note : le forgeage direct sur `:3001` (hors nginx) est trusté, mais **`:3001` n'est pas exposé
publiquement** (timeout depuis l'extérieur) → pas de surface d'attaque.

---

## BLOC 2 — D'où viennent les abonnements « en double »

### Constat central : ce ne sont PAS des doublons accidentels de concurrence

Le pattern des 12 utilisateurs à lignes multiples est presque toujours le même : **une ligne `free`
perpétuelle** (`current_period_end` en **2125/2126**, prix 0) **+ une ou plusieurs lignes payantes**.
La ligne `free` est le **socle gratuit créé à l'inscription** (par la RPC
`create_free_subscription_for_vendor`) ; elle coexiste **par conception** avec le plan payant.

- Les **3 utilisateurs « deux lignes actives »** (`ed8a00d0`, `69395eac`, `569276b0`) = **free + un
  premium à prix 0** (essai / offert), pas deux abonnements payants.
- **Aucune paire créée à quelques secondes** (signature d'une course concurrente). La plus rapprochée :
  `dad61558` à **~70 s** (double-clic probable) ; `fca38d2e` a **4 achats payants en 28 min**
  (13:36 → 14:04, chacun créant une ligne, les précédentes passant `expired`) = **rachats/montées de
  gamme séquentiels**, pas une race. Les autres paires sont espacées de plusieurs minutes à plusieurs
  jours (inscription → souscription plus tard).

### Contrainte en base : elle existe (partiellement)

```
idx_subscriptions_one_active_paid  UNIQUE (user_id)  WHERE status='active' AND price_paid_gnf > 0
```

→ **deux abonnements PAYANTS actifs simultanés sont déjà IMPOSSIBLES** (c'est précisément le cas
dangereux pour le masquage). En revanche free+free, free+payant, ou trialing+payant restent permis.
Le prompt supposait « probablement aucune contrainte » : il y en a une, ciblée sur le cas à risque.

### Tous les chemins d'écriture dans `subscriptions`

- **INSERT (créent une ligne)** :
  - `create_free_subscription_for_vendor` (RPC) → **le socle `free` perpétuel** (à l'inscription).
  - `src/routes/subscriptions.routes.ts:285` → souscription à un plan. **Check-then-insert NON atomique**
    (select active/trialing à la ligne 242, insert à la 285) : insère `status='active'` (gratuit) ou
    `'trialing'` (payant). Deux requêtes simultanées peuvent passer le check ensemble — mais pour un
    plan payant l'insert est `trialing`, et la bascule finale en `active` payant est bloquée par l'index
    ci-dessus → le pire cas est neutralisé.
  - Autres RPC pouvant créer une ligne : `purchase_vendor_subscription_atomic`, `subscribe_user`,
    `pdg_offer_subscription`, `subscribe_driver`, `purchase_driver_subscription_atomic`,
    `purchase_service_subscription_atomic`, `process_digital_subscription_renewal`,
    `record_service_subscription_payment`, `process_payment_by_type`.
  - `src/components/pdg/SubscriptionManagement.tsx:421` (frontend, outil PDG).
- **UPDATE seulement (ne créent pas de ligne)** : `jobQueue.ts:779` (expiration), `renew-subscription`
  `:172` (**update**, confirme le constat du prompt), `subscriptions.routes.ts` (activation `:922`,
  expiration `:909/:977`, annulation `:1026`), `subscription-expiry-check`, `production-cron-jobs`,
  `subscription-webhook`, `edge-functions/payments.routes.ts:980`.

### ⏳ Décision Thierno (rien codé)
1. **Faut-il consolider** le modèle (mettre à jour la ligne au renouvellement/montée de gamme au lieu
   d'empiler des lignes `expired`) ? Ce n'est **pas un bug de correction** (le masquage est déjà blindé
   par la garde `7210239` + l'index), mais un choix de propreté du modèle.
2. **Étendre l'index** à `trialing` ? Possible, mais (a) il faut d'abord nettoyer d'éventuels doublons,
   (b) il doit **préserver** la coexistence voulue free + payant. Ne pas créer sans validation.

---

## BLOC 3 — Trois incohérences de données

### 3.1 — La « commande » à `vendor_id` NUL n'est pas une commande
Elle n'est **pas** dans `orders` (0 ligne à `00000000-…`). C'est une entrée **`pos_sales`** :
`id=fc61f198`, `local_sale_id='x'`, `total_amount=0`, `status='completed'`, `sold_at=2026-06-16`.
→ **un POS de test à montant nul** avec un vendeur factice. À creuser côté code : le chemin de synchro
POS peut-il encore poser `vendor_id='00000000-…'` (repli quand le vendeur est absent) ? **Ne rien
supprimer sans validation.**

### 3.2 — « IB Business » : deux comptes, une même personne
| Compte | vendor_code | email | créé | produits | ventes | abonnement |
|---|---|---|---|---|---|---|
| A | VND0012 | `ccrismons@gmail.com` | 2026-06-29 18:05:59 | 0 | 0 | **free seul** |
| B | VND0013 | `sorycrb@gmail.com` | 2026-06-29 18:14:40 | 0 | 0 | premium payant |

Même `full_name` « Ibrahima Sory Barry », deux `user_id` distincts, créés à **~9 min d'intervalle** →
**double inscription** (deux emails). **Doublon proposé à supprimer : A (VND0012)** — free seul, aucune
activité ; B porte l'abonnement payant. **Ne pas supprimer sans validation de Thierno.**

### 3.3 — La table `sales` est vide : dette de schéma, pas un flux cassé
`sales` (0 ligne) n'est écrite **que** par la synchro offline frontend (`useOfflineSync.ts:63`, branchée
à `OfflineSyncPanel`, + un `useOfflineSales.ts` apparemment non importé). Le POS **actif** écrit dans
**`pos_sales`** (157 lignes). → `sales` est un **chemin offline secondaire jamais exercé** (aucun
événement offline n'y a jamais été rejoué), pas un flux critique cassé. À documenter comme dette /
candidat à suppression, après confirmation que `OfflineSyncPanel` n'est plus utilisé.

---

## BLOC 4 — Liens de paiement : jamais payés = abandon, pas flux cassé

Les 2 liens sont **`status='pending'`**, `paid_at`/`transaction_id`/`order_id`/`escrow_id` **nuls**,
`use_count=0` — mais **tous deux `viewed_at` renseigné** (page ouverte ~15-18 s après création).

Le code de règlement **existe et est cohérent** : `src/routes/paymentLinks.routes.ts:611` pose
`status='success'` + `paid_at` + `transaction_id` + `wallet_credit_status='pending_settlement'` à la
confirmation carte (Stripe), avec une branche **escrow** distincte (`hold_payment_link_escrow`). Le
statut « payé » est `'success'` (pas `'paid'`) ; **aucun des 2 liens n'a jamais atteint `'success'`**.

**Lecture : abandon à l'étape paiement / liens de test ouverts mais non réglés** — pas de preuve de flux
cassé (le chemin qui met `paid_at` est intact). Un point mineur à surveiller : le lien 1 a
`wallet_credit_status='pending_settlement'` alors que `status='pending'` (probablement une valeur posée
à la création d'un lien « wallet », le lien 2 est à `'none'`).

### ⏳ Décision / suite (rien codé)
Pour lever le doute à 100 %, faire **un vrai paiement de bout en bout** sur un lien de test (création →
page → carte → retour Stripe → `status='success'` → crédit wallet). **Non corrigé** ici : c'est un flux
qui touche l'argent, il mérite son propre passage.

---

## BLOC 5 — Seuil de similarité de la recherche par photo (5 mesures réelles)

Fonction `supabase/functions/visual-search/index.ts` **appelée en réel** (Gemini via Lovable) sur
5 vraies photos du catalogue. Formule : `similarité = min(0.95, 0.5 + score/100)`, avec
`score = 20 × (mots-clés présents dans le nom) + note × 5`. **Toutes les notes du catalogue = 0** → le
bonus note est toujours nul, donc `score = 20 × correspondances`.

| Photo (produit) | Mots-clés IA (extrait) | Résultats | Similarité affichée |
|---|---|---|---|
| Ventilateur Dove | ventilateur sur pied / colonne / DOVE | 1 (lui-même) | **0.70** |
| Massage gun | pistolet de massage / masseur / massage gun | 1 (lui-même) | **0.70** |
| Clé USB faster 64 Gb | clé USB / mémoire flash / 64 Go | 3 (les 3 « Clé USB ») | **0.70** |
| Led vidéo light | LED pocket video light / éclairage vidéo (anglais) | **0** | — |
| Micro cravate F11-2 | microphone sans fil / Lavalier | **0** | — |

### Ce que montrent les chiffres bruts
- **Le plancher 0.50 n'a PAS surgi** dans ces tests : aucun résultat hors-sujet n'est remonté. Sur ce
  petit catalogue, le repli-description (qui pourrait tirer des produits sans rapport) n'a pas ramené de
  bruit. Les valeurs possibles de similarité (notes=0) sont donc : **0.50 (0 correspondance / bruit),
  0.70 (1), 0.90 (2), 0.95 (plafond)**.
- **Mais le bug reste latent et réel** : par construction, tout produit remonté **par le repli-description
  sans aucune correspondance de mot-clé** s'afficherait à **0.50** (« manifestement rien à voir » présenté
  à 50 %). Le seuil sous lequel un résultat n'a aucun rapport est donc **0.50** (= score 0). Il ne s'est
  simplement pas manifesté faute d'un catalogue assez grand.
- **Problème plus visible aujourd'hui = le RAPPEL** : **2 photos sur 5 → 0 résultat**, parce que les
  mots-clés de l'IA (souvent anglais/techniques : « microphone », « LED pocket video light ») ne
  « matchent » pas en sous-chaîne les noms FR des produits (« Micro cravate », « Led vidéo light ») via
  `ilike '%mot%'`. De vraies correspondances sont **manquées**.

### ⏳ Décision Thierno (formule NON modifiée)
1. **Découpler la pertinence du plancher** : démarrer la similarité à 0 (pas 0.5) pour qu'un résultat
   sans correspondance tombe visiblement bas, et fixer un **seuil d'affichage** (ex. n'afficher que
   ≥ 0.70 = au moins une vraie correspondance).
2. **Améliorer le rappel** : matcher aussi la `category`/`description`/tags, normaliser accents/langue,
   plutôt qu'un simple `ilike` du nom. À arbitrer avant tout code.
