-- Create public-images bucket for restaurant logos, covers, and menu item images
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'public-images', 
  'public-images', 
  true,
  5242880, -- 5MB max
  ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/gif']
)
ON CONFLICT (id) DO NOTHING;

-- Allow public read access to all files
CREATE POLICY "Public read access for public-images"
ON storage.objects FOR SELECT
USING (bucket_id = 'public-images');

-- Allow authenticated users to upload files
CREATE POLICY "Authenticated users can upload to public-images"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (bucket_id = 'public-images');

-- Allow authenticated users to update their own files
CREATE POLICY "Authenticated users can update in public-images"
ON storage.objects FOR UPDATE
TO authenticated
USING (bucket_id = 'public-images');

-- Allow authenticated users to delete files
CREATE POLICY "Authenticated users can delete from public-images"
ON storage.objects FOR DELETE
TO authenticated
USING (bucket_id = 'public-images');