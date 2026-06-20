-- Créer le bucket restaurant-assets (public pour afficher les images)
INSERT INTO storage.buckets (id, name, public)
VALUES ('restaurant-assets', 'restaurant-assets', true)
ON CONFLICT (id) DO NOTHING;

-- RLS: lecture publique
CREATE POLICY "Public read restaurant assets"
ON storage.objects FOR SELECT
TO public
USING (bucket_id = 'restaurant-assets');

-- RLS: upload pour utilisateurs authentifiés
CREATE POLICY "Authenticated users can upload restaurant assets"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (bucket_id = 'restaurant-assets');

-- RLS: update pour utilisateurs authentifiés (leurs propres fichiers)
CREATE POLICY "Authenticated users can update restaurant assets"
ON storage.objects FOR UPDATE
TO authenticated
USING (bucket_id = 'restaurant-assets');

-- RLS: delete pour utilisateurs authentifiés
CREATE POLICY "Authenticated users can delete restaurant assets"
ON storage.objects FOR DELETE
TO authenticated
USING (bucket_id = 'restaurant-assets');