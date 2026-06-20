-- ============================================
-- BUCKET STORAGE POUR ENREGISTREMENTS SOS
-- ============================================
-- Date: 07 Décembre 2025
-- Description: Bucket sécurisé pour enregistrements audio/vidéo SOS

-- Créer bucket pour enregistrements SOS
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'sos-recordings',
  'sos-recordings',
  false, -- Privé, accès contrôlé par RLS
  524288000, -- 500 MB max par fichier
  ARRAY['video/webm', 'video/mp4', 'audio/webm', 'audio/mp4', 'audio/ogg']
)
ON CONFLICT (id) DO NOTHING;

-- ============================================
-- POLITIQUES RLS POUR SOS-RECORDINGS BUCKET
-- ============================================

-- Policy 1: Chauffeurs peuvent uploader leurs propres enregistrements
CREATE POLICY "Taxi drivers can upload SOS recordings"
ON storage.objects
FOR INSERT
WITH CHECK (
  bucket_id = 'sos-recordings'
  AND auth.role() = 'authenticated'
  AND (storage.foldername(name))[1] = 'recordings'
);

-- Policy 2: Bureau Syndicat peut voir tous les enregistrements
CREATE POLICY "Bureau can view all SOS recordings"
ON storage.objects
FOR SELECT
USING (
  bucket_id = 'sos-recordings'
  AND (
    -- Utilisateur authentifié est un bureau syndicat
    EXISTS (
      SELECT 1 FROM syndicate_bureaus
      WHERE president_email = auth.jwt() ->> 'email'
      OR president_phone = auth.jwt() ->> 'phone'
    )
    -- OU c'est le chauffeur qui a créé l'enregistrement
    OR auth.uid()::text = (storage.foldername(name))[2]
  )
);

-- Policy 3: Chauffeurs peuvent voir leurs propres enregistrements
CREATE POLICY "Drivers can view own SOS recordings"
ON storage.objects
FOR SELECT
USING (
  bucket_id = 'sos-recordings'
  AND auth.role() = 'authenticated'
);

-- Policy 4: Bureau peut supprimer enregistrements (après investigation)
CREATE POLICY "Bureau can delete SOS recordings"
ON storage.objects
FOR DELETE
USING (
  bucket_id = 'sos-recordings'
  AND EXISTS (
    SELECT 1 FROM syndicate_bureaus
    WHERE president_email = auth.jwt() ->> 'email'
  )
);

-- Policy 5: Service role a accès complet (pour Edge Functions)
CREATE POLICY "Service role full access to SOS recordings"
ON storage.objects
FOR ALL
USING (
  bucket_id = 'sos-recordings'
  AND auth.jwt() ->> 'role' = 'service_role'
);

-- ============================================
-- AJOUTER COLONNES À TABLE SOS ALERTS
-- ============================================

-- Ajouter colonnes pour tracking enregistrements
ALTER TABLE syndicate_sos_alerts
ADD COLUMN IF NOT EXISTS has_recording BOOLEAN DEFAULT false,
ADD COLUMN IF NOT EXISTS recording_url TEXT,
ADD COLUMN IF NOT EXISTS recording_uploaded_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS recording_duration_seconds INTEGER;

-- Index pour recherche rapide enregistrements
CREATE INDEX IF NOT EXISTS idx_sos_has_recording 
ON syndicate_sos_alerts(has_recording) 
WHERE has_recording = true;

CREATE INDEX IF NOT EXISTS idx_sos_recording_uploaded 
ON syndicate_sos_alerts(recording_uploaded_at) 
WHERE recording_uploaded_at IS NOT NULL;

-- ============================================
-- FONCTION POUR NETTOYER VIEUX ENREGISTREMENTS
-- ============================================

CREATE OR REPLACE FUNCTION cleanup_old_sos_recordings()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Supprimer enregistrements de plus de 90 jours (conformité RGPD)
  DELETE FROM storage.objects
  WHERE bucket_id = 'sos-recordings'
  AND created_at < NOW() - INTERVAL '90 days';

  -- Logger action
  RAISE NOTICE 'Nettoyage enregistrements SOS > 90 jours effectué';
END;
$$;

-- Créer job cron pour nettoyage automatique (à configurer dans Supabase Dashboard)
-- Fréquence recommandée: 1 fois par semaine

-- ============================================
-- COMMENTAIRES
-- ============================================

COMMENT ON COLUMN syndicate_sos_alerts.has_recording 
IS 'Indique si SOS possède un enregistrement audio/vidéo';

COMMENT ON COLUMN syndicate_sos_alerts.recording_url 
IS 'URL publique de l''enregistrement dans Supabase Storage';

COMMENT ON COLUMN syndicate_sos_alerts.recording_uploaded_at 
IS 'Date/heure de fin d''upload de l''enregistrement';

COMMENT ON COLUMN syndicate_sos_alerts.recording_duration_seconds 
IS 'Durée de l''enregistrement en secondes';

-- ============================================
-- GRANTS
-- ============================================

-- Permissions pour authenticated users
GRANT SELECT ON storage.objects TO authenticated;
GRANT INSERT ON storage.objects TO authenticated;

-- Permissions pour service_role
GRANT ALL ON storage.objects TO service_role;
GRANT ALL ON storage.buckets TO service_role;

-- ============================================
-- VERIFICATION
-- ============================================

-- Vérifier bucket créé
SELECT * FROM storage.buckets WHERE id = 'sos-recordings';

-- Vérifier politiques storage
SELECT * FROM pg_policies WHERE tablename = 'objects' AND policyname LIKE '%SOS%';

-- Vérifier nouvelles colonnes
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_name = 'syndicate_sos_alerts'
AND column_name IN ('has_recording', 'recording_url', 'recording_uploaded_at', 'recording_duration_seconds');
