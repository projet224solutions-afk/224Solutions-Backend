INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'digital-products', 
  'digital-products', 
  true,
  104857600,
  ARRAY[
    'application/pdf',
    'application/zip',
    'application/x-zip-compressed',
    'application/x-rar-compressed',
    'application/x-7z-compressed',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'application/epub+zip',
    'audio/mpeg',
    'audio/wav',
    'audio/ogg',
    'audio/flac',
    'audio/aac',
    'audio/mp4',
    'video/mp4',
    'video/webm',
    'image/jpeg',
    'image/png',
    'image/webp',
    'image/gif',
    'image/svg+xml',
    'text/plain',
    'text/csv',
    'application/json',
    'application/octet-stream'
  ]
)
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "Allow authenticated upload to digital-products"
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (bucket_id = 'digital-products');

CREATE POLICY "Allow public read digital-products"
ON storage.objects FOR SELECT TO public
USING (bucket_id = 'digital-products');

CREATE POLICY "Allow owner update digital-products"
ON storage.objects FOR UPDATE TO authenticated
USING (bucket_id = 'digital-products' AND (storage.foldername(name))[1] = auth.uid()::text);

CREATE POLICY "Allow owner delete digital-products"
ON storage.objects FOR DELETE TO authenticated
USING (bucket_id = 'digital-products' AND (storage.foldername(name))[1] = auth.uid()::text);