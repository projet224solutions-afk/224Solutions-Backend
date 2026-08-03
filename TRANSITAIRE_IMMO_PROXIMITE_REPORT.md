# TRANSITAIRE_IMMO_PROXIMITE_REPORT

Date : 2026-08-03. Prod `uakkxaibujzxdiqzpnpr`.

---

## CHANTIER A — TRANSITAIRE

### A.1 — Dashboard branché aux VRAIES données ✅ LIVRÉ (frontend `f09cc56b9`)
- **Fin des données fictives** : suppression des 2 fausses lignes `INT-2024-089/090` et du statut douanier
  codé en dur (`recentCustoms`).
- `useTransitaireStats` **n'est plus un stub** : lit `international_shipments` du transitaire connecté
  (RLS `transitaire_id = auth.uid()`) → total / en cours / livrées / revenu (Σ `shipping_cost`) / en douane.
- `useTransitaireShipments` (nouveau) : liste réelle des expéditions ; statut douanier **agrégé par pays réel**.
- **État vide propre** : « Aucune expédition en cours — créez votre première » + skeletons. i18n `transit.*`.
- Vérif : `tsc` 0 · `vitest` 274/274 · `vite build` OK.

### A.2–A.6 — Création / suivi / documents / paiement — ⚠️ BLOQUÉ par une décision d'ARCHITECTURE
Constat schéma (audit base) qui empêche de « créer une expédition depuis le devis » proprement :
- **`international_shipments.order_id` est NOT NULL** et pointe `orders` → cette table modélise « expédier
  une COMMANDE marketplace à l'international », **pas** une expédition de fret autonome (client qui envoie un
  colis Conakry→Paris depuis le calculateur).
- **`shipments`** = livraison **vendeur domestique** (vendor_id, cash_on_delivery) → pas de pays/mode/incoterm.
- Donc **il n'existe aucune table pour une expédition de fret autonome**, et **aucun circuit escrow fret**
  existant (l'escrow actuel = `service_quotes` prestations / caution immobilier).

**Décision requise (Thierno) avant de construire A.2–A.6 — je ne crée pas un chemin d'argent à l'aveugle :**
- **Option 1** (recommandée) : rendre `international_shipments.order_id` **nullable** + ajouter les champs pro
  (mode maritime/aérien, villes origine/destination, expéditeur/destinataire, colis, valeur déclarée, incoterm,
  `client_user_id`, machine à états `booked→collecté→transit→douane→dédouané→livré`, référence auto `EXP-…`).
- **Escrow fret** : réutiliser le **même patron atomique** que les prestations (un devis de fret payé en
  séquestre, libéré à la livraison confirmée) — RPC dédiées `pay_freight_atomic`/`release_freight_atomic`
  calquées sur `pay_quote_atomic` (0 nouveau mécanisme, même idempotence/atomicité).
- Documents (`customs_documents` jsonb existe déjà) + timeline client (réutiliser le composant taxi/livraison).

Dès ton feu vert sur l'option, je livre A.2→A.6 en une passe (migration + UI + preuve escrow annulée).

---

## CHANTIER B — IMMOBILIER (séquestre caution) — CONFIRMÉ, rien cassé

- **Location = séquestre caution OK** (confirmé en base) :
  - Entrée : `start_rental_lease_atomic` (signature du bail) → `rental_leases.deposit_status` (colonne présente).
  - Sortie : `settle_deposit` / `release_deposit_atomic` (retenue bornée + motif + remboursement + contestation).
- **⚠️ ACHAT de bien = AUCUNE sécurisation d'argent** : pas de table `property_purchases`/`property_offers`
  → l'achat est une **simple mise en relation** (contact/visite), pas d'acompte séquestré.
  **À trancher (Thierno)** : soit acompte séquestré libéré à la remise des clés (même patron que la caution),
  soit assumer l'achat hors plateforme (grosses sommes) — non forcé, comme demandé.
- **RESTE à vérifier (non audité ce passage)** : écran client « caution séquestrée, rendue en fin de bail » à
  l'entrée + « Mes locations/achats » avec état de caution. À confirmer sur appareil ou passage dédié.

---

## CHANTIER C — PROXIMITÉ

- **La page inclut DÉJÀ immobilier ET transitaire** (`Proximite.tsx` : immobilier l.97, transitaire l.291,
  cartes toujours rendues) **+ une partie dynamique** : `extraTypes` chargés depuis `service_types` actifs
  (hors set `COVERED`) → un **type généré apparaît sans redéploiement**.
- **Diagnostic SQL de visibilité (compteurs) :**
  ```
  immobilier  : 2 prestataires actifs · 2 biens (properties)   → carte visible, compteur > 0
  transitaire : 0 prestataire actif   · 0 expédition           → carte visible, compteur 0 (réalité, pas un filtre)
  ```
  ⇒ Le transitaire « n'apparaît pas peuplé » simplement parce qu'**aucun prestataire transitaire n'est encore
  enregistré** — la carte, elle, est bien présente. Immobilier a 2 prestataires → compteur réel.
- **Politique de visibilité sans abonnement** : NON tranchée ici (comme demandé). Les cartes connues ne sont pas
  masquées par l'abonnement (elles sont toujours rendues) ; seul le compteur reflète le nombre de prestataires.

---

## Bilan
- **A.1 livré + prouvé** (fini les fausses expéditions). **A.2–A.6 en attente d'une décision d'archi** (schéma
  fret + escrow fret) — je ne bâtis pas un chemin d'argent sur une base ambiguë.
- **B** : séquestre caution **location** confirmé (intact) ; **achat** = mise en relation (constat, à trancher).
- **C** : immobilier + transitaire **déjà présents** en proximité ; diagnostic chiffré fourni ; transitaire=0 car
  0 prestataire enregistré (pas un bug de filtre).

**« Dashboard transitaire branché au réel (fini les données fictives), séquestre caution immo confirmé,
immobilier + transitaire présents en proximité — le 2026-08-03. Reste : décision archi fret pour la création/
paiement d'expéditions. »**
