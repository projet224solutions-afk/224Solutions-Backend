# DEVISE_PAR_PAYS_REPORT

Date : 2026-08-05. Chantier ÉTAGÉ — socle + écrans des captures (VENDEUR) livrés ; le reste planifié par rôle.

## ✅ Socle (règle « une source, un formateur ») — l'infra EXISTAIT, elle est maintenant NOMMÉE
- **`useUserCurrency()`** (nouveau, `src/hooks/`) : façade sur la brique qui marche déjà
  (usePriceConverter/CurrencyContext = devise du WALLET en base, verrouillée ; fallback pays ; GNF en dernier).
- **`formatMoney(amount, currency)`** (nouveau, `src/lib/`) : formateur NATIF central (décimales/séparateurs) —
  AUCUNE conversion (règle FX en panne). Pour l'affichage CONVERTI : `<Money>`/`useMoneyFormat` (inchangés).
- **Fallback FX natif : DÉJÀ implémenté** dans `usePriceConverter` (taux manquant/à 0 → montant + devise
  D'ORIGINE, rate 1, pas de crash, pas de conversion silencieuse) — vérifié dans le code, rien à changer.

## ✅ VENDEUR (les captures Sierra Leone) — cause racine + fix
**Cause** : les montants du vendeur (ventes, stock, prix produits) sont stockés DANS SA devise, mais affichés
avec `from='GNF'` en dur → FX en panne = « 70 800 GNF » sur un compte SLE, tooltip « GNF » sur un axe SLE.
**Fix (affichage NATIF, from = SA devise → identité, juste dans tous les cas)** :
- `VendorAnalyticsDashboard` : stats (Ventes aujourd'hui, CA mois, Panier moyen) + graphique (données ET
  **tooltip** — le mélange de la capture) → devise du vendeur.
- `ProductManagement` : **« Prix de vente * (SLE) » dynamique** (plus de « (GNF) » en dur), Valeur Stock,
  aperçu commission d'affiliation → devise du vendeur.

## ✅ Langue par pays
`LanguageContext.initialLanguage()` : niveau ajouté — **langue du PAYS détecté** (cache géo : SL→en, SN→fr)
entre le choix manuel (qui PRIME, inchangé) et navigator/fr. Guinée → fr (non-régression).

## 📋 ABONNEMENTS — état pour DÉCISION Thierno (comme demandé)
Les plans vendeur (capture « 25 000 GNF ») sont **stockés en GNF** et affichés via `<Money from='GNF'>` →
convertis quand le FX marche, sinon « GNF » affiché assumé (pas de mélange silencieux). Des **grilles par pays
existent déjà** (module country_pricing, appliqué prod) mais l'écran plans vendeur ne les consomme pas.
**Décision à trancher : brancher les grilles par pays sur cet écran, ou rester conversion FX.**

## ⏳ RESTE (plan par rôle, ~380 hardcodes hors vendeur-captures — chantier par étapes, sessions suivantes)
1. VENDEUR restant (POS, étiquettes, historique) → même patron (devise du vendeur, natif).
2. PRESTATAIRE (devis/factures/séquestre — factures déjà par devise événement côté billetterie).
3. TAXI/VTC/LIVREUR (courses, gains). 4. CLIENT (commandes, paiements). 5. PDG (agrégats PAR devise).
6. MARKETPLACE : les items portent déjà `currency` (produits/offerings/événements → carte affiche la devise
   du produit ; tri déjà normalisé GNF via `toGnf`) — à auditer table par table pour le backfill `currency`.
Patron unique à appliquer : montant de l'utilisateur → devise du wallet (natif) ; montant d'autrui → `<Money
from=devise_d_origine>` (conversion + fallback natif).

Vérifs : tsc 0 · vitest 274/274 · build OK · i18n 25/25.
**« Chaque pays a sa devise et sa langue partout (socle posé + écrans vendeur des captures corrigés,
fallback natif sans FX), le 2026-08-05 — déploiement par rôle en cours. »**
