-- Create product-images storage bucket
INSERT INTO storage.buckets (id, name, public)
VALUES ('product-images', 'product-images', true)
ON CONFLICT (id) DO NOTHING;

-- Create storage policies for product images
CREATE POLICY "Anyone can view product images"
ON storage.objects FOR SELECT
USING (bucket_id = 'product-images');

CREATE POLICY "Vendors can upload product images"
ON storage.objects FOR INSERT
WITH CHECK (
  bucket_id = 'product-images' AND
  (EXISTS (
    SELECT 1 FROM vendors
    WHERE vendors.user_id = auth.uid()
    AND (storage.foldername(name))[1] = vendors.id::text
  ))
);

CREATE POLICY "Vendors can update their product images"
ON storage.objects FOR UPDATE
USING (
  bucket_id = 'product-images' AND
  (EXISTS (
    SELECT 1 FROM vendors
    WHERE vendors.user_id = auth.uid()
    AND (storage.foldername(name))[1] = vendors.id::text
  ))
);

CREATE POLICY "Vendors can delete their product images"
ON storage.objects FOR DELETE
USING (
  bucket_id = 'product-images' AND
  (EXISTS (
    SELECT 1 FROM vendors
    WHERE vendors.user_id = auth.uid()
    AND (storage.foldername(name))[1] = vendors.id::text
  ))
);