# SERVICES_COHERENCE_REPORT — socle commun créer/modifier/photos/suivi

Date : 2026-08-03. Livraison **incrémentale** (chaque partie testée + poussée séparément).

---

## PARTIE 1 — PRESTATIONS ✅ LIVRÉ (frontend `750ed1d08`)

1. **Modifier une prestation** : `useServiceOfferings.update(id, patch)` (RLS owner `check_service_owner` ;
   une prestation n'est PAS un devis payé → éditable à tout moment). Bouton **« Modifier »** (crayon) sur
   chaque prestation → dialog **pré-rempli** → « Enregistrer les modifications ». Titre + bouton adaptés
   création vs édition.
2. **Modèles élargis** (`serviceOfferingTemplates.ts`, +15) :
   - **Bureautique** : CV pro, mise en page mémoire/rapport, Excel (formules), PowerPoint pro, saisie de données.
   - **Graphisme** : charte graphique, flyer/affiche, bannière réseaux, carte de visite (+ logo déjà présent).
   - **Vidéo & Motion** : montage vidéo (pub/événement), montage court (TikTok/statut), habillage/intro motion.
   - **Audio & Photo** : retouche photo pro, enregistrement/montage audio.
3. **Image** : le champ existant = image de la PRESTATION (OK, `service_offerings.image_url`).
   ⏳ **Logo prestataire distinct** (sur `professional_services`/vitrine) : l'écran d'édition du profil
   prestataire n'a pas été localisé de façon fiable ce passage → à brancher avec le bon composant (reste).

**Vérif** : `tsc` 0 · `vitest` 274/274 · `vite build` OK · i18n 25.

---

## PARTIE 2 — IMMOBILIER (édition complète + galerie photos) — ✅ LIVRÉ (frontend `7d55545da`)
- **`updateProperty(id, patch)`** (RLS owner) : édite prix/description/surface/pièces/type/quartier…
- **`NewPropertyDialog` réutilisé en ÉDITION** (prop `editProperty`) : pré-remplissage, titre/bouton adaptés,
  + **galerie EXISTANTE** via `PropertyImageUpload` (couverture, ordre, suppression — table `property_images`,
  déjà présente) + ajout rapide de photos.
- **`PropertyCard`** : entrée menu **« Modifier l'annonce »** ; `RealEstateModule` route create vs update.
- **Séquestre caution INCHANGÉ** (non-régression). `tsc` 0 · `vitest` 274/274 · `build` OK.

---

## PARTIE 3 — TRANSITAIRE (opérationnel) — ✅ BACKBONE LIVRÉ (backend `f35a23b`, frontend `5accab15e`)
- **Migration** `20260803130000` : `international_shipments.order_id` **nullable** + champs pro (mode,
  villes, expéditeur/destinataire, colis, valeur déclarée, incoterm, `client_user_id`, `status` machine à
  états, `reference` `EXP-…`, `quote_id`) ; **table `intl_shipment_events`** (le suivi ; ⚠️ `shipment_tracking`
  est lié à `shipments` domestique) + RLS parties.
- **RPC `create_freight_shipment`** : **PRIX SERVEUR recalculé** via `calculate_freight_quote` (jamais le
  client), réf auto, statut `booked`, 1ᵉʳ événement, notif client. REVOKE anon.
- **RPC `advance_shipment_status`** : machine à états horodatée + notif client + **garde transitaire owner**.
  **Preuve (rollback)** : advance → `delivered` + `actual_delivery` + **3 événements** ; non-owner **REFUSÉ**.
- **Frontend** : `useTransitaireShipments.createShipment/updateShipmentStatus` + **sélecteur « Faire avancer »**
  par expédition dans le dashboard (statut courant + progression).
- **Escrow fret** = circuit EXISTANT (`service_quotes` + `pay_quote_atomic`/`release_quote_atomic`) via
  `quote_id` — **0 nouveau chemin d'argent** (colonne posée ; création du quote à câbler côté UI).

### ⏳ Reste PARTIE 3 (UI, prochaine passe — backbone prouvé prêt) :
- **« Créer l'expédition »** depuis `FreightQuoteCalculator` (formulaire expéditeur/destinataire → `createShipment`).
- **Timeline client** (composant taxi/livraison sur `intl_shipment_events`) sur la fiche expédition client.
- **Documents** (`customs_documents` jsonb, pipeline fichiers) + onglets Documents/Mes expéditions.
- **Câblage escrow** : créer le `service_quote` du fret (payable) + release à `delivered`.

---

## PARTIE 4 — Socle d'actions réutilisable — ⏳ (recommandé, non bloquant)
Factoriser un motif « entité de service » (créer/modifier/supprimer/photos) dans `service-common`.

---

## État
- **PARTIE 1 : livrée + poussée + verte.**
- PARTIES 2, 3, 4 : planifiées, livrées incrémentalement aux prochaines passes (chacune testée + poussée).

_À compléter au fur et à mesure — phrase finale « Services de proximité cohérents… » posée quand 1→3 sont livrés._
