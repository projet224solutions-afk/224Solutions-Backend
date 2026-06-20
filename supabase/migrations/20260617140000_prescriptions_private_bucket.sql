-- ============================================================================
-- SERVICE PHARMACIE — SÉCURITÉ : bucket PRIVÉ pour les photos d'ordonnances.
--
-- FAILLE : les photos d'ordonnances étaient uploadées dans le bucket PUBLIC
-- `communication-files` (folder 'documents') → données MÉDICALES lisibles par
-- n'importe qui via l'URL publique permanente (sans authentification). Donnée de
-- santé = confidentialité stricte.
--
-- CORRECTION (modèle digital-products) : bucket dédié `prescriptions` PRIVÉ.
--   • Upload : authentifié, UNIQUEMENT sous son propre préfixe <uid>/... (un user ne
--     peut pas écrire dans le dossier d'un autre).
--   • AUCUNE policy de lecture anon/authenticated → les fichiers ne sont accessibles
--     QUE via le backend (service_role) qui génère des URLs signées courtes (5 min),
--     après vérification que le demandeur est le client propriétaire OU le pharmacien
--     destinataire (voir route GET /api/v2/pharmacy/prescriptions/:id/photos).
-- Idempotent.
-- ============================================================================

INSERT INTO storage.buckets (id, name, public)
VALUES ('prescriptions', 'prescriptions', false)
ON CONFLICT (id) DO UPDATE SET public = false;

-- Upload réservé à l'utilisateur dans SON dossier (1er segment du chemin = son uid).
DROP POLICY IF EXISTS prescriptions_insert_own ON storage.objects;
CREATE POLICY prescriptions_insert_own ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'prescriptions' AND (storage.foldername(name))[1] = auth.uid()::text);

-- Upsert (remplacement) dans son propre dossier.
DROP POLICY IF EXISTS prescriptions_update_own ON storage.objects;
CREATE POLICY prescriptions_update_own ON storage.objects FOR UPDATE TO authenticated
  USING (bucket_id = 'prescriptions' AND (storage.foldername(name))[1] = auth.uid()::text)
  WITH CHECK (bucket_id = 'prescriptions' AND (storage.foldername(name))[1] = auth.uid()::text);

-- Suppression dans son propre dossier (nettoyage avant envoi).
DROP POLICY IF EXISTS prescriptions_delete_own ON storage.objects;
CREATE POLICY prescriptions_delete_own ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = 'prescriptions' AND (storage.foldername(name))[1] = auth.uid()::text);

-- Pas de policy SELECT : la lecture passe exclusivement par le backend (URLs signées).

SELECT 'Pharmacie : bucket prescriptions PRIVÉ + policies upload scopées (lecture via backend signé).' AS status;
