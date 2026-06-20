-- Mettre à jour le bucket communication-files pour accepter tous les types de fichiers audio
UPDATE storage.buckets 
SET allowed_mime_types = array_cat(
  COALESCE(allowed_mime_types, ARRAY[]::text[]),
  ARRAY[
    'audio/mp4',
    'audio/m4a', 
    'audio/x-m4a',
    'audio/mpeg',
    'audio/mp3',
    'audio/webm',
    'audio/ogg',
    'audio/wav',
    'audio/aac',
    'audio/x-aac',
    'audio/flac',
    'audio/*'
  ]::text[]
)
WHERE id = 'communication-files';

-- Si le bucket n'a pas de restrictions, on peut aussi le mettre à null pour tout autoriser
-- Alternative: autoriser tous les types
UPDATE storage.buckets 
SET allowed_mime_types = NULL
WHERE id = 'communication-files';