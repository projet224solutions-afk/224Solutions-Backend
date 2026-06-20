-- ================================================================
-- FIX payment_links.vendeur_id — rendre nullable pour prestataires
--
-- Problème :
--   vendeur_id est NOT NULL + FK vers vendors(id).
--   Les prestataires de services (professional_services) n'ont pas
--   forcément de compte vendeur → le hook usePaymentLinks passe
--   '00000000-0000-0000-0000-000000000000' qui n'existe pas dans
--   vendors → FK violation → création de lien impossible.
--
-- Fix :
--   1. Supprimer la contrainte NOT NULL sur vendeur_id
--   2. Conserver la FK (intégrité si vendeur_id est renseigné)
-- ================================================================

ALTER TABLE public.payment_links
  ALTER COLUMN vendeur_id DROP NOT NULL;

SELECT 'payment_links.vendeur_id est maintenant nullable.' AS status;
