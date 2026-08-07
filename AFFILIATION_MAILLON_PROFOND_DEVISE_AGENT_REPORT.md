# Affiliation — maillon profond : commission créditée en devise de l'agent, conversion tracée

Clôture du seul item staged du chantier 2.2. **Livré et PROUVÉ.** Le `credit_user_wallet_safe`
(primitif partagé escrow/dépôts/remboursements) **n'est PAS modifié** — la conversion tracée se fait
en amont, dans la chaîne de commission uniquement.

## Ce qui change (migration additive `20260807180000`)
1. **Traçage** : `agent_commissions_log` gagne `credited_currency`, `credited_amount`, `fx_rate`,
   `fx_rate_at`, `fx_source` (lignes historiques NULL = documenté).
2. **`credit_agent_wallet_gnf`** : le wallet dépensable de l'agent est crédité **DANS SA DEVISE**,
   conversion GNF→devise via **`_acash_fx`** (taux + date + source, garde de fraîcheur 24 h), et la
   trace est écrite sur la ligne de commission. Ancienne signature 2-args **droppée** (évite un
   doublon de surcharge = alerte `money_integrity`).
3. **`credit_agent_commission`** : **PRÉ-VOL FX fail-closed** (sous-agent + parent, et agent direct) —
   si un agent à créditer a un wallet non-GNF **sans taux frais**, la fonction ne touche à **RIEN**
   (pas de log, pas de crédit, pas de débit PDG) et renvoie `fx_pending`. Le split (15/5, plafond)
   et la base (fee facturé mémorisé) sont **inchangés**.
4. **`triggerAffiliateCommission`** (TS) : `fx_pending` → `affiliate_commission_enqueue` (raison
   `FX_DOWN`, idempotent par `(source_type, source_ref)`). Le job leader-gardé reverse au retour du
   taux (distingue désormais `pending` de `resolved`).
5. **Gardien** : 4ᵉ check `affiliate_untraced_conversion` (high) = commission créditée en devise
   étrangère **sans taux tracé** (détecteur de régression du traçage).

## Sur le `currency:'GNF'` codé en dur (commission.service.ts)
Il est **conservé** et **correct** : c'est la devise de **BASE** du log (`agent_commissions_log.currency`),
car la commission est calculée sur une base GNF débitée du wallet GNF du PDG. La **devise réelle de
l'agent** est désormais portée par les **nouvelles colonnes tracées** (`credited_currency` = XOF/EUR/…,
`fx_rate`, `fx_source`). Le retirer mentirait sur la base. L'intention de la règle (« l'agent reçoit
dans SA devise, tracé ») est **satisfaite** par le crédit réel + le traçage.

## Preuves (prod, transactions ANNULÉES — aucun argent réellement déplacé)
| Scénario | Résultat |
|---|---|
| Agent **GNF** (cas courant, inchangé) | `credited_currency=GNF, credited_amount=2000, fx_rate=1, fx_source=identity` |
| Agent **XOF** (commission 2000 GNF) | `credited_currency=XOF, credited_amount=129, fx_rate=0.0647…, fx_source=currency_exchange_rates` (converti & **tracé**) |
| Agent en devise **sans taux frais** | `fx_pending=true`, **0 ligne de log** (aucune mutation, fail-closed) |
| **Cycle complet** panne → attente → retour | panne `fx_pending` → 1 pending → retour taux (XOF) → **versé, credited XOF, taux tracé** → pending **resolved** |
| Gardien (4 checks) | **0/0/0/0** sur données saines |

## Sécurité de l'application
Migration encapsulée `BEGIN;…COMMIT;` → atomique : une erreur = tout annulé, anciennes fonctions
intactes (aucune casse possible). Le comportement est **fail-closed** : au pire une commission passe
en attente (récupérable), **jamais** perdue ni créditée à un taux non tracé/périmé.

## Vérifications
`tsc` backend **0** · migration appliquée · gardien 4 checks **0** · toutes les injections prouvées en
transaction annulée.

## Reste (DIT)
- Décision PDG sur la commission de **dépôt** des utilisateurs créés (dormante — inchangé, hors de ce maillon).
- Abonnements : base **GNF-native** (pas de leg fee→GNF) ; le leg GNF→devise agent bénéficie AUSSI de
  ce maillon (même `credit_agent_wallet_gnf`) → couverts, pending si l'agent est non-GNF sans taux.

Commit : `1c9ff9b`.
