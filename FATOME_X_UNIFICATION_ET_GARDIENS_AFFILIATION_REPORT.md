# Fatome X — unification de la surveillance + gardiens des commissions d'affiliation

Trois chantiers. **Chantier 1 & 2 LIVRÉS et PROUVÉS. Chantier 3 = diagnostic livré (décision PDG).**

---

## CHANTIER 1 — Fatome = point de convergence de TOUTE la surveillance ✅

**Avant** : l'étage B n'escaladait que `commission_revenue_gap*` → la carte Fatome PDG était borgne
(ni escrow, ni coffre, ni AML, ni agent cash…).

**Après** (`surveillance24x7.service.ts`, TS pur, aucun SQL neuf) :
- **UN SEUL run** des monitors : `runPlatformMonitors` synchronise system_alerts PUIS son rapport est
  RÉUTILISÉ pour la 2e synchro (Fatome) — jamais deux appels RPC.
- L'étage B itère **CHAQUE domaine** du registre (escrow, dispute, transfer, order, wallet, pos, aml,
  money_integrity, pdg_treasury, agent_cash, fx, frontend_security, **affiliate**). Check **high/critical**
  en anomalie → `fatome_raise('<domaine>:<key>', 'monitor:<domaine>:<key>:<jour>', sévérité, {…})`.
  **medium/low → system_alerts seulement** (pas de bruit Fatome). Check repassé à 0 → `fatome_resolve_type`.
- **Notification unique** : `system_alerts` n'a AUCUN trigger de notification ; seul `fatome_raise` notifie,
  **une fois par (type, réf) datée** → 1 notification PDG/anomalie/jour. Pas de double notif.
- **Carte PDG** (`FatomeSentinelleCard.tsx`) : badge DOMAINE (🔒 Escrow, 👛 Wallet, 🛡️ AML, 🏦 Coffre PDG,
  🤝 Affiliation…) parsé du préfixe `<domaine>:`.

**Preuves** : escalade `escrow:currency_mismatch` → 1 anomalie, **idempotente** (2e raise = 1 ligne),
**1 notification**, résolution → 0. `escrow_monitor_report` expose un **vrai** `released_no_ledger`
(high, count=2) désormais visible avec badge escrow. Cutover : 3 anciennes anomalies `commission_revenue_gap`
(type nu) résolues.

---

## CHANTIER 2 — Gardiens de la chaîne commissions d'affiliation ✅

**Avant** : 0 gardien ; `orders.routes:798` → taux absent → `gnfFee=0` → **commission ignorée EN SILENCE**.

**Après** :
- **Migration NOUVELLE `20260807170000`** : table `affiliate_commission_pending` (idempotente par
  `(source_type, source_ref)`) + RPC `enqueue` / `pending_list` / `pending_mark` + **gardien**
  `affiliate_commission_monitor_report` (fenêtre 7 j, format monitor standard) :
  - `affiliate_gap` (**high**) : commande payée, frais > 0, vendeur à agent ACTIF (`get_user_agent`),
    aucune commission tracée ni en attente ;
  - `affiliate_split_invalid` (**critical**) : somme des parts (sous-agent + parent) > plafond des frais ;
  - `affiliate_pending_overdue` (**high**) : commissions en attente > 24 h.
  Enregistré dans `MONITOR_DOMAINS` → **l'étage B (chantier 1) l'escalade automatiquement** (badge 🤝 Affiliation)
  + `SUGGESTED_FIX` pour chaque check.
- **Fin du silence** (`orders.routes.ts`) : conversion frais→GNF **TRACÉE par Fatome** (`_acash_fx` : taux
  + date + source, garde de fraîcheur 24 h) au lieu du spot brut. **Pas de taux frais → la commission passe
  EN ATTENTE** (`affiliate_commission_enqueue`, idempotent par order_id) — **jamais perdue**.
- **Job leader-gardé** (`surveillance24x7`, ~5 min) : reverse les pending dès qu'un taux frais existe
  (convert `_acash_fx` → `triggerAffiliateCommission`, **idempotent**).

**Règle métier appliquée** : la commission est **convertie par Fatome** (`_acash_fx`, taux tracé) et créditée
dans **la devise du wallet de l'agent** (le moteur `credit_agent_commission` → `credit_user_wallet_safe`
crédite déjà le wallet de l'agent dans SA devise). Panne/no-rate → **attente** → versement auto au retour.

**Preuves (prod, transaction ANNULÉE — aucun argent réellement déplacé)** :
- Gardien sur données réelles = **0 / 0 / 0** (sain).
- Enqueue **idempotent** (2× même ref = 1 ligne) ; `affiliate_pending_overdue` détecte un pending backdaté
  >24 h (+1) ; `pending_list` le renvoie ; `pending_mark('resolved')` → overdue revient à 0.
- **Cycle complet** : enqueue → `_acash_fx(2000 XOF)` = **30 900 GNF (taux 15,4498 tracé, source
  currency_exchange_rates)** → `credit_agent_commission` (success, has_agent) → `agent_commissions_log`
  **0→1** → **wallet agent GNF 40 000 → 46 180** (+6 180 = 20 % de 30 900, **devise de l'agent**) → pending
  **resolved** → re-run → log **reste à 1** (**idempotent**).

### Abonnements
Les commissions d'abonnement passent par `triggerAffiliateCommission(userId, price_paid_gnf, 'abonnement', …)`
avec un prix **déjà en GNF** (pas de conversion cross-devise de la base) → **pas de cas NO_RATE** à mettre en
attente. Elles sont **couvertes par le gardien** (`affiliate_split_invalid` inclut `source_type='abonnement'`)
et par le même moteur de crédit (→ devise de l'agent). Conforme à la règle, sans pending nécessaire.

### ⏳ Reste (DIT, non fait) — enrichissement staged
- **Traçage de la conversion FINALE GNF→devise de l'agent** dans `credit_user_wallet_safe` (rate+date+source
  stockés dans `agent_commissions_log`). Aujourd'hui la conversion vers la devise de l'agent existe déjà mais
  au spot **non tracé** ; le leg frais→GNF (order path) est désormais tracé (`_acash_fx`). Le traçage du 2e leg
  = modification du cœur `credit_user_wallet_safe` (RPC argent live) → increment dédié + preuve par point.
- Le `currency:'GNF'` de `commission.service.ts` est **laissé** : le montant transmis EST en GNF (base), donc
  le label GNF du log est **correct** — le changer sans le redesign agent-currency ci-dessus mentirait. À
  retirer EN MÊME TEMPS que ce redesign.

---

## CHANTIER 3 — UTILISATEURS créés par agents : DIAGNOSTIC (décision PDG) ⚠️

**Fait business à remonter — la prémisse du chantier vise une chaîne MORTE ; la capacité vivante existe
ailleurs et a DÉJÀ une devise.**

| Élément (prémisse) | État prouvé |
|---|---|
| `calculate_agent_commission(p_user_id,p_type,p_amount)` | **MORTE** — 2 surcharges, **0 appelant**, **droppées** (`20260702120000_cleanup_dup_functions_money.sql:22-26`, commentaire « LES DEUX MORTES »). |
| table `agent_commissions` (sans `currency`) | **MORTE** — plus aucun écrivain vivant (tous supersédés/droppés), aucun trigger, non lue côté TS. |
| Capacité « commission sur activité d'un utilisateur créé » | **VIVANTE via un AUTRE moteur** : `credit_agent_commission` → **`agent_commissions_log`**, car `get_user_agent` lit `agent_created_users`. |
| `agent_commissions_log.currency` | **EXISTE DÉJÀ** (ajoutée `20260325045345`). |

**Chemin réel par événement d'un utilisateur créé** :
| Événement | Chemin | État |
|---|---|---|
| **Abonnement** | `subscriptions.routes` → `triggerAffiliateCommission` → `credit_agent_commission` → `get_user_agent` lit `agent_created_users` → `agent_commissions_log` | **VIVANT** |
| **Achat produit** | commission versée à l'agent du **VENDEUR** (décision marketplace), pas à l'agent créateur de l'acheteur | VIVANT (autre bénéficiaire) |
| **Dépôt wallet** | `payments.routes:631` = appel **COMMENTÉ** ; `wallet.v2:29` = import mort | **DORMANT** |

**Conséquences (aucune implémentation « en douce »)** :
1. **Rien à assainir** : la chaîne legacy est déjà supprimée par le cleanup des doublons ; la chaîne vivante
   converge sur le moteur du chantier 2 (même `credit_agent_commission` / `agent_commissions_log`).
2. **Migration `currency` sur `agent_commissions` : INUTILE** — cette table est morte ; la table vivante
   `agent_commissions_log` a déjà `currency`. Ajouter une colonne à une table morte serait du bruit.
3. **La règle métier du chantier 2 couvre DÉJÀ les utilisateurs créés** : `get_user_agent` résout aussi bien
   `agent_created_users` (créés) que `user_agent_affiliations` (affiliés) → même conversion Fatome, même
   crédit devise-agent, même gardien.
4. **DÉCISION PDG requise** : verser une commission sur le **DÉPÔT WALLET** d'un utilisateur créé est
   **DORMANT** (jamais câblé : appel commenté). **Les agents n'ont donc JAMAIS touché de commission sur les
   dépôts de leurs utilisateurs créés.** Remise en vie = décision business (brancher `triggerAffiliateCommission`
   sur le dépôt, source_type `wallet_deposit`, avec la même règle Fatome). **NON implémenté** ici — à trancher
   par le PDG (c'est un choix de modèle, pas un bug).

---

## Règles respectées
- Migrations NOUVELLES ; aucun flux d'argent existant modifié — **le pending remplace le silence**, il ne
  change pas le calcul (split 15/5, plafond, base = fee facturé : inchangés).
- Triggers/jobs : **jamais bloquants, leader-gardés** (surveillance24x7), best-effort try/catch, gatés par
  compteur de cycles (coût maîtrisé).

## Vérifications
| Contrôle | Résultat |
|---|---|
| `tsc` backend | **0** |
| `tsc` frontend (badge) | **0** |
| Migration `20260807170000` appliquée en prod | **OK** (gardien 0/0/0 sur données saines) |
| Preuves d'injection | escrow (raise/idempotent/notif/resolve) ; affiliation (enqueue/overdue/cycle complet/idempotent) — **toutes en transaction annulée** |

## Commits
- Backend : `2bf635f` (CH1 convergence), `4d447dc` (CH2 gardien+pending+retry). Frontend : `254a566b1` (CH1 badge).

## Fait / Reste
- ✅ **Fait** : CH1 convergence + badge (prouvé) ; CH2 gardien + file d'attente + de-silencing + retry
  (prouvé, cycle complet en devise agent) ; CH3 diagnostic complet.
- ⏳ **Reste (DIT)** : (a) traçage du 2e leg de conversion (GNF→devise agent) dans `credit_user_wallet_safe`
  + retrait synchronisé du label `currency:'GNF'` — increment dédié sur RPC argent live. (b) Décision PDG sur
  la commission de **dépôt** des utilisateurs créés (dormante — jamais versée). (c) Observation « < 2 cycles »
  de la convergence Fatome en conditions réelles = runtime du service (logique prouvée en base).
