-- ============================================================================
-- 🔐 SÉCURISATION DES FICHIERS DE MESSAGERIE - 224SOLUTIONS
-- ============================================================================
-- PROBLÈME : le bucket `communication-files` était PUBLIC (policy "Public read
-- access" TO public). Toutes les pièces jointes (photos, vocaux, documents
-- privés) étaient accessibles par n'importe qui via l'URL, sans authentification.
--
-- CORRECTION :
--   1. Le bucket devient PRIVÉ (public = false).
--   2. Lecture / écriture / suppression réservées aux utilisateurs authentifiés.
--   3. L'accès aux fichiers se fait désormais via des URLs signées à durée
--      limitée (générées côté client, voir src/lib/communication/fileUrls.ts).
--
-- NB : la policy d'upload historique exigeait foldername[1] = auth.uid(), or le
-- service écrit dans `communication/<conversationId>/...` (1er dossier =
-- "communication"). Elle est remplacée par une policy cohérente.
-- ============================================================================

-- 1) Rendre le bucket privé
UPDATE storage.buckets
SET public = false
WHERE id = 'communication-files';

-- 2) Supprimer les anciennes policies (lecture publique + upload incohérent)
DROP POLICY IF EXISTS "Public read access" ON storage.objects;
DROP POLICY IF EXISTS "Users can upload their own files" ON storage.objects;
DROP POLICY IF EXISTS "Users can delete their own files" ON storage.objects;

-- 3) Lecture : utilisateurs authentifiés uniquement (URLs signées)
CREATE POLICY "comm_files_authenticated_read"
ON storage.objects FOR SELECT
TO authenticated
USING (bucket_id = 'communication-files');

-- 4) Upload : utilisateurs authentifiés (chemin applicatif `communication/...`)
CREATE POLICY "comm_files_authenticated_insert"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (bucket_id = 'communication-files');

-- 5) Mise à jour (upsert) : authentifiés
CREATE POLICY "comm_files_authenticated_update"
ON storage.objects FOR UPDATE
TO authenticated
USING (bucket_id = 'communication-files')
WITH CHECK (bucket_id = 'communication-files');

-- 6) Suppression : authentifiés
CREATE POLICY "comm_files_authenticated_delete"
ON storage.objects FOR DELETE
TO authenticated
USING (bucket_id = 'communication-files');
