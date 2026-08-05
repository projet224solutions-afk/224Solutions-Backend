# SCANNER_TEXTE_REPORT

Date : 2026-08-05. Migration `20260805140000` APPLIQUÉE prod.

## ✅ OCR par VISION IA (zéro lib OCR — infra copilote réutilisée)
- Route `POST /api/v2/scanner/extract` : dataURL JPEG/PNG/WebP ≤1024px (compression CLIENT, même
  pipeline que la vision copilote) → **redondance 3 providers** (Anthropic → Lovable/Gemini → OpenAI),
  prompt strict « extrais UNIQUEMENT le texte, conserve la structure », FR/EN, imprimé ET manuscrit.
- **verifyJWT + rate-limit 30/jour/utilisateur** (`SCAN_TEXT_DAILY_LIMIT` configurable) — facture IA protégée.
- Échec propre : `[AUCUN_TEXTE]` → « réessayez avec plus de lumière » + option **garder la photo avec
  note manuelle** ; service indisponible → 503 explicite. Pas de crash, pas de spinner infini.

## ✅ Notes mémorisées (« Mes documents scannés », /scans)
- Table `provider_scanned_notes` (RLS owner strict — un prestataire ne voit QUE ses notes).
- Bouton 📷 proéminent (caméra mobile `capture=environment` ou galerie) → texte extrait dans un
  **éditeur** → titre auto (1re ligne) → Enregistrer (photo d'origine optionnelle sur GCS).
- Liste avec vignettes + **recherche plein-texte** + édition (updated_at) + suppression confirmée.
- **Attache à un devis** (liste de SES devis) / détache — badge « Devis » sur la note.
- Accès : bouton « Scanner » dans le dashboard service (2 variantes) + le Studio.

**« Scanner de texte prestataire (vision IA, notes mémorisées modifiables) le 2026-08-05. »**
