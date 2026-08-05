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

---
## VAGUE 2-3 (2026-08-05, suite) — rôles déroulés
**Patron appliqué (montant DE l'utilisateur → SA devise, natif via `useUserCurrency`)** :
- **VENDEUR** : `POSSystem` (19 hits — devise de BASE du POS = celle du vendeur : annotations « (X GNF) »
  et bascule de devise recalculées sur `baseCur`), `AffiliateManagement` (CA 30j + prix), `DirectSaleForm`
  (suffixes devise), `PaymentProcessor` (libellés de frais gabarit `{cur}`), `PurchaseEditor` (B2B),
  `VendorDeliveryPricing` (bornes /km).
- **PRESTATAIRE** : `quoteForms` artisan (vitrerie/métal/plomberie/menuiserie — catalogues affichés dans SA
  devise), `ServiceAnalytics` (formateur paramétré ; le composant utilisait déjà userCurrency),
  `DeliveryModule` (grille indicative).
- **LIVREUR** : `DriverPriceSettings` (bornes tarif/km).
- **CLIENT** : `MyBeautyAppointments` (remboursement), `CashConfirm` + `ClientCashConfirm` (dépôt/retrait cash
  agent), `StripeWalletTopup` (recharge), `CardPaymentDialog` + `CardTransactionsHistory` (carte virtuelle),
  `AffiliationHub` (gains), `B2BQuickSendBar`, `QuickPaymentLinkButton`.

**Reliquat (81 lignes, ASSUMÉ — pas des bugs)** :
- **PDG/admin (28)** : trésorerie/limites/rapports = devise PLATEFORME GNF (coffre PDG) — correct ; agrégats
  multi-devises PAR devise = évolution PDG à trancher.
- **Dropshipping/import Chine (4+)** : flux d'achat réellement facturés en GNF (clés i18n dédiées conservées).
- **Design224 (3)** : page de démo design. — **Marketplace « dès X GNF » (2)** : phase audit `currency` par
  table (produits modules) — planifiée.
Vérifs : tsc 0 · vitest 274/274 · build OK.

---
## DÉCISION VALIDÉE Thierno (2026-08-05) : plans d'abonnement = GRILLES PAR PAYS
- **Backend `/api/subscriptions/purchase`** (source de vérité du débit) : le prix vient de
  `subscription_prices` (grille du pays de `profiles.country_code`, service_type='vendor',
  plan_code=plan.name) en **devise LOCALE** (= devise du wallet, verrouillée → débit direct juste).
  Annuel = 12 × mensuel grille avec le MÊME rabais % que le plan. Prorata upgrade/downgrade inchangé
  (les deux montants sont dans la devise de l'utilisateur). Métadonnées : `pricing_source`
  (country_grid|gnf_fallback), `pricing_country`, `pricing_currency`.
- **Revenu coffre PDG** : journalisé avec la **devise réelle** du montant (fini `p_currency: 'GNF'`
  menti pour un paiement EUR/XOF).
- **Repli fail-honest** : pays sans grille → prix GNF assumé + `logger.warn` « grille manquante »
  (le PDG crée la grille via son écran Country Pricing existant) + mention UI « Tarif en GNF ».
- **Front `VendorSubscriptionPlanSelector`** : affiche la grille NATIVEMENT (`formatCountryPrice`,
  zéro FX) avec la MÊME règle de calcul que le backend ; repli `<Money from='GNF'>` sinon.
- **État des grilles (prod)** : 4331 lignes, 7 pays (GN, SN, CI, ML, MA, FR, US) — **⚠️ Sierra Leone
  ABSENTE : grille SL à créer par le PDG** (sinon les vendeurs SL voient le repli GNF assumé).

---
## RÈGLE RENFORCÉE (2026-08-05) — fini les fixes partiels : « GNF » substitué AU NIVEAU DE t()
**Constat capture XOF** : « Prix de vente (XOF) » corrigé mais « Prix barré (GNF) » / « Prix de revient
(GNF) » restés — car le « GNF » vit dans les VALEURS i18n (~86 clés × 25 langues).
**Solution structurelle (un point, pas 86×25 retouches)** : `t()` substitue désormais `\bGNF\b` par la
devise d'affichage de l'utilisateur (singleton `lib/displayCurrency` alimenté par CurrencyContext) :
- Utilisateur GNF (Guinée) → identité TOTALE (zéro régression).
- Utilisateur SLE/XOF/NGN… → TOUTES les étiquettes traduites mentionnant « GNF » (labels, placeholders,
  aides, toasts) affichent SA devise — dans les 25 langues d'un coup, y compris les écrans pas encore
  balayés. **Sûr** : vérifié qu'AUCUNE valeur i18n ne contient de montant chiffré en GNF (grep = 0) —
  la substitution ne touche que des étiquettes de devise (qui désignent la devise de saisie de
  l'utilisateur → sémantiquement correcte).
→ Le formulaire produit complet (vente/barré/revient) est cohérent dans la devise de l'utilisateur, et
  tout futur écran l'est PAR DÉFAUT. Les hardcodes JSX restants (hors i18n) suivent le balayage par
  vagues déjà en cours (voir sections précédentes) — la substitution t() couvre l'immense majorité
  du visible dès maintenant.
