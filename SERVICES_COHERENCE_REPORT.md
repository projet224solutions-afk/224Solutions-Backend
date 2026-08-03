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

## PARTIE 2 — IMMOBILIER (édition complète + galerie photos) — ⏳ À VENIR
Plan : `updateProperty(id, patch)` (RLS owner) + bouton « Modifier l'annonce » ; galerie photos via le
pipeline `useStorageUpload` (couverture + galerie, réordonnancement, suppression) → table `property_images`
(à vérifier/étendre) ; affichage fiche client + placeholder `<SafeImage>` si aucune photo. **Séquestre caution
inchangé** (non-régression). Livré + prouvé en une passe.

---

## PARTIE 3 — TRANSITAIRE (opérationnel) — ⏳ À VENIR (le plus gros)
Décision d'archi désormais **confirmée par le prompt** (créer/suivre). Plan :
- Migration : rendre `international_shipments.order_id` **nullable** + champs pro (mode maritime/aérien,
  villes origine/dest, expéditeur/destinataire, colis, valeur déclarée, incoterm, `client_user_id`,
  référence auto `EXP-2026-xxxxxx`, machine à états).
- `createShipment` (depuis le devis de fret, prix serveur figé) + `updateShipmentStatus`
  (`booked→collecté→transit→douane→dédouané→livré`, horodaté dans `shipment_tracking`).
- Timeline client (composant taxi/livraison) + notifications ; documents (`customs_documents` jsonb) ;
  **escrow fret** calqué sur `pay_quote_atomic`/`release_quote_atomic` (0 nouveau chemin d'argent).
- Onglets : Dashboard / Nouveau devis / Mes expéditions / Documents / Communication.

---

## PARTIE 4 — Socle d'actions réutilisable — ⏳ (recommandé, non bloquant)
Factoriser un motif « entité de service » (créer/modifier/supprimer/photos) dans `service-common`.

---

## État
- **PARTIE 1 : livrée + poussée + verte.**
- PARTIES 2, 3, 4 : planifiées, livrées incrémentalement aux prochaines passes (chacune testée + poussée).

_À compléter au fur et à mesure — phrase finale « Services de proximité cohérents… » posée quand 1→3 sont livrés._
