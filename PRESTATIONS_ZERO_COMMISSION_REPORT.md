# PRESTATIONS_ZERO_COMMISSION_REPORT — 0 commission (abonnement seul) + limites + image

Date : 2026-08-03. Projet prod `uakkxaibujzxdiqzpnpr`. Migrations appliquées via API Management,
prouvées en base (transactions de preuve **annulées** → aucun mouvement d'argent réel persisté).

---

## CORRECTION 1 — ZÉRO commission sur les devis de prestation (CRITIQUE, argent)

Migration `20260803100000_service_quotes_zero_commission.sql`.

### Diff `pay_quote_atomic` (périmètre `service_quotes` UNIQUEMENT)
Retiré : `resolve_service_commission_rate` + `v_commission` + le débit `total_amount + v_commission`
+ le crédit commission au PDG (escrow ET direct) + `credit_agent_commission`.
Désormais :
- Client débité **EXACTEMENT `total_amount`** (description : `Paiement devis : <titre>`, sans « + commission »).
- Escrow → `held` puis prestataire crédité **100 %** à la libération ; direct → prestataire **100 %** immédiat.
- **Rien au PDG.** Atomicité + idempotence (`quote-pay-<id>`) préservées.

### Diff `preview_commission`
Flux `'quote'` → `rate := 0` (commission 0). Flux `rent` / `restaurant` / `artisan` **inchangés**.
`release_quote_atomic` crédite déjà 100 %, aucune commission → **inchangé**.

### Preuve chiffrée (transaction annulée, prestation FIXE 250 000 GNF escrow)
```
preview_commission('quote') → { rate:0, commission:0, amount:250000, total:250000 }
pay_quote_atomic            → { escrow:true, success:true }
release_quote_atomic        → { released:250000 }
client débité   = 250 000   (attendu 250 000)   ✓  (plus de +10 %)
prestataire     = +250 000  (attendu 250 000)   ✓  (100 %)
PDG             = +0        (attendu 0)          ✓
```

### Non-régression MARKETPLACE PRODUITS (commerçants) — INCHANGÉ
```
get_purchase_commission_percent()        = 5
calculate_purchase_commission(250000)    = (rate 5, commission 12500, net 237500)   ✓ toujours prélevée
```
Fonctions produits (`apply_platform_commission`, `pay_with_commission`, `calculate_purchase_commission`)
**non modifiées** — la migration ne remplace que `pay_quote_atomic` + `preview_commission` (chemin services).

### Aucun autre prélèvement résiduel sur les prestations
`pay_quote_atomic` (0 commission), `release_quote_atomic` (0), `wallet_debit_internal` (pas de frais).
`wallet_pay_quote` = paiement **QR vendeur** (`vendor_payment_qr`), PAS un devis de service → hors périmètre.

---

## CORRECTION 2 — Modèle d'abonnement (limites par métier) — VÉRIFICATION (état réel, aucun changement)

### Limites gratuites PAR MÉTIER (colonne `max_products` du plan `free` de chaque `service_type`)
```
beaute 3 · construction 2 · education 1 · location 1 · informatique 2 · freelance 3 · media 3 ·
reparation 5 · maison 3 · agriculture 5 · ecommerce 10 · restaurant 10 · clinique 30 · pharmacie 30 ·
digital_livre/logiciel 2 · dropshipping 2 · livraison 2 · menage 2 · sante 2 · sport 2 · vtc 2 · (défaut) 2
```
→ **Conforme à la décision : limites par métier conservées (pas d'uniformisation).**

### Application (trigger `enforce_service_product_cap`)
Sur **`beauty_services`, `farm_products`, `restaurant_menu_items`** : prend le plan payant actif, sinon le
plan `free` du métier ; compte les éléments ; au-delà → **EXCEPTION avec message clair** « Limite de N
éléments atteinte pour votre plan d'abonnement. Passez à un plan supérieur… » (pas de blocage muet ni crash).

### ⚠️ Constats à trancher par le PDG (NON modifiés ici, comme demandé)
1. **`service_offerings` (prestations IT) n'est PAS gardé par la limite d'abonnement** — seulement par un
   **plafond dur de 30** (`service_offerings_max_per_service`). Donc un prestataire IT gratuit
   (`informatique` = 2) peut publier **jusqu'à 30** prestations, pas 2. Si tu veux que l'abonnement gate
   AUSSI les prestations IT → il faut ajouter `enforce_service_product_cap` sur `service_offerings`
   (décision + montant par métier à confirmer).
2. **Visibilité** : la proximité/marketplace filtre `professional_services` sur `status='active'`
   uniquement — **pas** sur l'abonnement. Un service sans abonnement payant reste visible (il a un plan
   `free`). À trancher séparément (politique essai/gratuit) si tu veux masquer au-delà de la limite.

---

## CORRECTION 3 — Image de la prestation (champ ajouté)

Migration `20260803110000_service_offerings_image.sql` : colonne `image_url text` sur `service_offerings`
(appliquée + vérifiée).

- **Formulaire « Proposer une prestation »** (`ServiceOfferingsManager`) : champ **image de couverture**
  via le pipeline existant (`useStorageUpload` → compression + GCS, bucket public), avec **aperçu** et
  **bouton retirer** (X).
- **Clarification UI** : libellé « **Image de la prestation** » + aide « *le visuel du service proposé
  (différent de votre logo/photo de profil)* ». → l'image de la PRESTATION est distincte du logo/profil du
  PRESTATAIRE (porté par `professional_services`/vitrine, non touché ici).
- **Cartes** (client `PublicOfferingsList` + liste owner) : affichent l'image ; **placeholder propre**
  (dégradé + icône) si absente — jamais de carré cassé (images via `<SafeImage>`, garde `no-raw-img` OK).
- i18n : `serviceOfferings.imagePrestation/.imagePrestationAide/.retirerImage/.uploadEchoue` (25 langues).

---

## Vérifications
- Commission services retirée : **250 000 → 250 000, PDG 0** (preuve chiffrée). ✓
- Marketplace produits **intact** : commission 5 % toujours calculée (12 500 sur 250 000). ✓
- Limites abonnement **par métier** confirmées + appliquées (message clair) ; 2 constats remontés au PDG. ✓
- Aucun prélèvement résiduel sur les prestations. ✓
- Image : upload + aperçu + retirer ; prestation vs logo clarifié ; placeholder si absente. ✓
- Front : `tsc` 0 · `vitest` 274/274 · `vite build` OK · `check:i18n` 25 langues.

**« Prestations sans commission (abonnement seul) le 2026-08-03, marketplace produits inchangé. »**
