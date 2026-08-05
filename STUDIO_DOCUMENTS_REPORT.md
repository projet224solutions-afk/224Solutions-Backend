# STUDIO_DOCUMENTS_REPORT

Date : 2026-08-05. « Fini Word/Excel » — /studio, mobile-first.

## ✅ Catalogue : 9 catégories × 3 styles = 27 designs (`documentTemplates.ts`, extensible)
💍 Mariage (A5) · ✉️ Invitation (A6) · 💼 **Carte de visite 85×55 mm** · 📋 Administratif (A4) ·
📢 Flyer (A5) · 🖼️ Affiche (A3) · 🍽️ Menu (A5) · 📄 CV (A4, colonne latérale) · 🎫 Badge (86×122).
Styles Élégant/Moderne/Coloré factorisés (ajouter un design = ce fichier uniquement). Champs par
catégorie ({noms mariés, date, lieu…} / {nom, fonction, tél…}), photos/logos via pipeline GCS.

## ✅ Flux : catégorie → design (aperçus réels) → champs → APERÇU EN DIRECT → export
- **PDF prêt à imprimer** : format exact en mm + **fond perdu 3 mm** (jsPDF au format réel), zone de
  sécurité par le padding des layouts. **PNG** pour WhatsApp. Rendu html2canvas ≈152 dpi (léger mobile).
- **« Mes documents »** (`provider_documents`, RLS owner) : ré-ouvrable → modifier → ré-exporter ;
  **Dupliquer** en 1 tap (le geste métier) ; client optionnel.
- **« Mes modèles »** (`provider_document_templates`) : « Enregistrer comme modèle » → réutilisable
  pour le client suivant (valeurs par défaut).
- **« Partir d'un document scanné »** : choisir une note OCR → le texte reste affiché EN SOURCE à côté
  pendant la création. Honnêteté produit affichée : « reproduisez le CONTENU avec un de nos designs »
  (pas de promesse de clonage graphique).

Vérifs : tsc front+back 0 · vitest 274/274 · build OK · i18n 25/25 (≈100 clés scans+studio).
⚠️ Tests réels device restants : un scan de carton réel (vision IA en prod) + un export PDF depuis téléphone.
**« Studio de documents prestataire (modèles + champs, fini Word) le 2026-08-05. »**
