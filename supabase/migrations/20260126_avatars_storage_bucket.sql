-- ============================================
-- MIGRATION: Bucket avatars pour photos de profil
-- 224SOLUTIONS - Vista Flows
-- ============================================

-- Créer le bucket avatars avec une limite de 10 Mo
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'avatars',
  'avatars', 
  true,
  10485760, -- 10 Mo en bytes
  ARRAY['image/jpeg', 'image/png', 'image/gif', 'image/webp']
)
ON CONFLICT (id) DO UPDATE SET
  file_size_limit = 10485760,
  allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/gif', 'image/webp'];

-- ============================================
-- NOTE: Les policies de stockage doivent être créées
-- via le Dashboard Supabase > Storage > Policies
-- ou via l'API REST avec le service_role key
-- ============================================

-- Policies à créer manuellement dans le Dashboard:
--
-- 1. SELECT (public): bucket_id = 'avatars'
-- 2. INSERT: bucket_id = 'avatars' AND auth.uid()::text = (storage.foldername(name))[1]
-- 3. UPDATE: bucket_id = 'avatars' AND auth.uid()::text = (storage.foldername(name))[1]  
-- 4. DELETE: bucket_id = 'avatars' AND auth.uid()::text = (storage.foldername(name))[1]
