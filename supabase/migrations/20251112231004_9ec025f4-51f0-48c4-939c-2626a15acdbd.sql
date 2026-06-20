-- Ajouter des colonnes pour les informations du badge
ALTER TABLE public.vehicles 
ADD COLUMN IF NOT EXISTS driver_photo_url TEXT,
ADD COLUMN IF NOT EXISTS driver_date_of_birth DATE;

-- Créer un bucket de stockage pour les photos des conducteurs si nécessaire
INSERT INTO storage.buckets (id, name, public)
VALUES ('driver-photos', 'driver-photos', true)
ON CONFLICT (id) DO NOTHING;

-- Politiques RLS pour le bucket driver-photos
CREATE POLICY "Public Access for driver photos"
ON storage.objects FOR SELECT
USING (bucket_id = 'driver-photos');

CREATE POLICY "Authenticated users can upload driver photos"
ON storage.objects FOR INSERT
WITH CHECK (
  bucket_id = 'driver-photos' AND
  auth.role() = 'authenticated'
);

CREATE POLICY "Authenticated users can update driver photos"
ON storage.objects FOR UPDATE
USING (
  bucket_id = 'driver-photos' AND
  auth.role() = 'authenticated'
);

CREATE POLICY "Authenticated users can delete driver photos"
ON storage.objects FOR DELETE
USING (
  bucket_id = 'driver-photos' AND
  auth.role() = 'authenticated'
);