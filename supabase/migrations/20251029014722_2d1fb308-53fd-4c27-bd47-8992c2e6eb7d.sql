-- Créer un bucket pour les fichiers de communication
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'communication-files',
  'communication-files',
  true,
  20971520, -- 20MB
  ARRAY['image/jpeg', 'image/png', 'image/gif', 'image/webp', 
        'video/mp4', 'video/quicktime', 'video/webm',
        'audio/mpeg', 'audio/wav', 'audio/ogg', 'audio/webm',
        'application/pdf', 'application/msword', 
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'application/vnd.ms-excel',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        'text/plain', 'text/csv']
);

-- Politiques RLS pour le bucket communication-files

-- Les utilisateurs authentifiés peuvent uploader des fichiers dans leurs conversations
CREATE POLICY "Users can upload files to their conversations"
ON storage.objects
FOR INSERT
WITH CHECK (
  bucket_id = 'communication-files'
  AND auth.role() = 'authenticated'
  AND (storage.foldername(name))[1] = 'communication'
);

-- Tous les utilisateurs authentifiés peuvent voir les fichiers de communication
CREATE POLICY "Authenticated users can view communication files"
ON storage.objects
FOR SELECT
USING (
  bucket_id = 'communication-files'
  AND auth.role() = 'authenticated'
);

-- Les utilisateurs peuvent supprimer leurs propres fichiers
CREATE POLICY "Users can delete their own communication files"
ON storage.objects
FOR DELETE
USING (
  bucket_id = 'communication-files'
  AND auth.uid()::text = (storage.foldername(name))[2]
);