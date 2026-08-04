# BILLET_VISUEL_REPORT

Date : 2026-08-04. 100 % frontend (la colonne `events.cover_image` existait déjà).

## ✅ 1 — Upload de l'affiche par le PRESTATAIRE
Création d'événement (`/billetterie`) : champ **« Affiche / logo »** (jpg/png/webp ≤ 8 Mo, pipeline
`useStorageUpload` compression/GCS) → `events.cover_image`. Aperçu + bouton retirer. UNE seule source d'image.

## ✅ 2 — Billet SOIGNÉ (PDF + in-app)
`eventTicketPdf.ts` refondu :
- **Bandeau affiche pleine largeur** en tête (cadrage « cover » sans déformation, voile pour lisibilité du
  titre) ; **fallback élégant** = dégradé orange→bleu 224Solutions + titre (jamais de billet cassé).
- Infos hiérarchisées : titre (blanc sur bandeau), 📅 date/heure, 📍 lieu, **pastille type de billet**
  (VIP/Standard), prix, titulaire, n° unique.
- **Séparateur talon pointillé** + **QR ENCADRÉ** (cadre orange arrondi, **84 mm, 512px, jamais déformé** —
  le scan prime) + mentions anti-fraude. UTF-8/accents OK.
- **In-app** (`/billet/:token`) : même identité — bandeau affiche (SafeImage) ou dégradé + titre.
- **Email** : lien vers le billet in-app (même rendu) — inchangé.

## ✅ 3 — Cohérence marketplace/partage (une seule source)
- Page `/evenement/:id` : affiche affichée (poster de la vidéo promo, ou image seule) ; **og:image de partage**
  = `cover_image` (ShareButton imageUrl). Marketplace : `loadPromotedEvents` utilisait déjà `cover_image`.

Vérifs : tsc 0 · vitest 274/274 (SafeImage, cliquet no-raw-img respecté) · build OK · i18n 25/25.
⚠️ À re-tester sur téléphone : un scan réel du QR du nouveau PDF (taille/contraste conservés — 512px inchangé).

**« Billets générés avec affiche/logo de l'événement (jolis + QR scannable) le 2026-08-04. »**
