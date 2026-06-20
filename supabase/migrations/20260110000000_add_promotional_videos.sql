-- Migration: Ajout support vidéos publicitaires produits (Premium)
-- Date: 2026-01-10
-- Description: Ajoute colonne promotional_video et bucket storage pour vidéos

-- 1. Ajouter colonne promotional_video à la table products
ALTER TABLE products 
ADD COLUMN IF NOT EXISTS promotional_video text;

COMMENT ON COLUMN products.promotional_video IS 'URL vidéo publicitaire (max 10s, Premium uniquement)';

-- 2. Créer le bucket pour les vidéos publicitaires
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'product-videos',
  'product-videos',
  true,
  52428800, -- 50MB max
  ARRAY['video/mp4', 'video/quicktime', 'video/x-msvideo', 'video/webm', 'video/x-matroska']
)
ON CONFLICT (id) DO NOTHING;

-- 3. Configurer les policies pour le bucket product-videos

-- Policy: Les vendeurs peuvent uploader leurs vidéos
CREATE POLICY "Vendors can upload videos" ON storage.objects
FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'product-videos' AND
  (storage.foldername(name))[1] IN (
    SELECT vendor_id::text 
    FROM vendors 
    WHERE user_id = auth.uid()
  )
);

-- Policy: Tout le monde peut voir les vidéos (public)
CREATE POLICY "Anyone can view videos" ON storage.objects
FOR SELECT TO public
USING (bucket_id = 'product-videos');

-- Policy: Les vendeurs peuvent supprimer leurs vidéos
CREATE POLICY "Vendors can delete their videos" ON storage.objects
FOR DELETE TO authenticated
USING (
  bucket_id = 'product-videos' AND
  (storage.foldername(name))[1] IN (
    SELECT vendor_id::text 
    FROM vendors 
    WHERE user_id = auth.uid()
  )
);

-- Policy: Les vendeurs peuvent mettre à jour leurs vidéos
CREATE POLICY "Vendors can update their videos" ON storage.objects
FOR UPDATE TO authenticated
USING (
  bucket_id = 'product-videos' AND
  (storage.foldername(name))[1] IN (
    SELECT vendor_id::text 
    FROM vendors 
    WHERE user_id = auth.uid()
  )
);

-- 4. Créer index pour optimiser les requêtes sur promotional_video
CREATE INDEX IF NOT EXISTS idx_products_promotional_video 
ON products(promotional_video) 
WHERE promotional_video IS NOT NULL;

-- 5. Fonction pour nettoyer les vidéos orphelines
CREATE OR REPLACE FUNCTION cleanup_orphaned_videos()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Supprimer les entrées storage qui ne correspondent plus à aucun produit
  -- URL format: https://{project}.supabase.co/storage/v1/object/public/product-videos/{path}
  DELETE FROM storage.objects
  WHERE bucket_id = 'product-videos'
  AND name NOT IN (
    SELECT 
      SUBSTRING(promotional_video FROM '/product-videos/(.+)$')
    FROM products
    WHERE promotional_video IS NOT NULL
    AND promotional_video LIKE '%/product-videos/%'
  );
END;
$$;

COMMENT ON FUNCTION cleanup_orphaned_videos IS 'Nettoie les vidéos dans storage qui ne sont plus liées à aucun produit';

-- 6. Créer trigger pour supprimer vidéo lors de la suppression du produit
CREATE OR REPLACE FUNCTION delete_product_video()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  video_path text;
BEGIN
  -- Si le produit avait une vidéo, la supprimer du storage
  IF OLD.promotional_video IS NOT NULL AND OLD.promotional_video LIKE '%/product-videos/%' THEN
    BEGIN
      -- Extraire le chemin depuis l'URL complète
      -- URL format: https://{project}.supabase.co/storage/v1/object/public/product-videos/{path}
      video_path := SUBSTRING(OLD.promotional_video FROM '/product-videos/(.+)$');
      
      IF video_path IS NOT NULL THEN
        DELETE FROM storage.objects
        WHERE bucket_id = 'product-videos'
        AND name = video_path;
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        -- Ignorer les erreurs de suppression storage
        NULL;
    END;
  END IF;
  
  RETURN OLD;
END;
$$;

-- Créer le trigger
DROP TRIGGER IF EXISTS trigger_delete_product_video ON products;
CREATE TRIGGER trigger_delete_product_video
BEFORE DELETE ON products
FOR EACH ROW
EXECUTE FUNCTION delete_product_video();

COMMENT ON TRIGGER trigger_delete_product_video ON products IS 'Supprime automatiquement la vidéo du storage quand le produit est supprimé';
