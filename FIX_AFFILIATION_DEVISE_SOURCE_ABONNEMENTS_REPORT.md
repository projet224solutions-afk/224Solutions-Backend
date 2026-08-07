# Fix affiliation — devise SOURCE des abonnements (base de calcul)

Bug corrigé de bout en bout. **Chirurgical** : le maillon GNF→devise-agent (livré) et le chemin
marketplace ne sont pas cassés — ils sont UNIFIÉS sur le même point de conversion.

## Le bug
Abonnements tarifés par pays (XOF/SLE/EUR…) mais les 6 appels
`triggerAffiliateCommission(userId, price, 'abonnement', id)` passaient le montant BRUT, étiqueté GNF
en dur → un abonnement 5 000 XOF traité comme base 5 000 GNF (au lieu de 77 249) → agent sous-payé
~14× (XOF), ~10 000× (EUR). Le revenu PDG, lui, était juste (recordSubscriptionRevenue reçoit déjà la devise).

## Correctif
1. **Signature** : `triggerAffiliateCommission(userId, amount, type, transactionId?, amountCurrency='GNF')`.
2. **Conversion source→GNF DANS le service** (un seul endroit) via `_acash_fx` (taux frais, TRACÉ :
   colonnes `base_currency/base_amount/base_fx_rate/base_fx_rate_at/base_fx_source` sur agent_commissions_log).
   Taux indisponible → **PENDING `NO_RATE_SOURCE`** (devise SOURCE conservée) — jamais de base fausse,
   jamais d'abandon silencieux.
3. **6 sites abonnement** : vendeur /purchase (509, 561) passent `pricingCurrency || 'GNF'` ; service/
   chauffeur/confirm (717, 764, 883, 978) passent `'GNF'` (GNF-natifs, mirror de recordSubscriptionRevenue).
4. **Marketplace unifié** : `orders.routes` passe `feeCur` au service (plus de conversion locale ni de
   skip silencieux) → UN seul point de conversion, cas « taux absent » → pending.
5. **Job de reprise** : repasse (montant + devise SOURCE) au service → convertit source→GNF puis
   GNF→devise agent (les DEUX legs tracés), idempotent par transaction_id.
6. **Rattrapage** versionné (`affiliate_backfill_subscription_ccy`, idempotent, clé
   md5('rattrapage_sub_ccy:'||sub_id)).

## Preuves (prod, transactions ANNULÉES)
- **5 000 XOF** → base GNF **77 249** → commission **15 449,80 GNF** (bug : ~1 000) ; source[XOF, 15,4498]
  + agent[GNF] tracés.
- **20 EUR** → base **202 593 GNF**, commission **40 519 GNF** (bug : ~4). **120 SLE** → base **42 730**,
  commission **8 546 GNF**.
- **Cycle NO_RATE_SOURCE** : panne source → pending → retour du taux → versé sur base correcte →
  resolved → re-run **idempotent** (une seule commission).
- **Marketplace** : non-régression par construction (même `_acash_fx` ; GNF inchangé) ; skip silencieux
  → pending.

## Rattrapage : PRÉVENTIF, coût nul (prouvé)
Requête prod : **0 souscription non-GNF** (subscriptions / service / driver). 1 seule commission
d'abonnement, GNF. → **Aucun agent n'a été sous-payé** ; `affiliate_backfill_subscription_ccy()` =
**0 rattrapées / 0 ignorées**. Le fix est préventif pour les futurs abonnements multi-pays. Le gardien
`affiliate_gap` reste à 0.

## Vérifications
`tsc` backend **0** · migration `20260807190000` appliquée · gardien 4 checks · toutes les injections
en transaction annulée. Migrations nouvelles ; pas de sur-vente.
