-- ===================================================
-- MIGRATION: Garantir que tous les vendeurs ont des slugs
-- Date: 2026-01-09
-- Objectif: S'assurer que 100% des boutiques ont un slug SEO-friendly
-- ===================================================

-- 1. Générer les slugs pour tous les vendeurs qui n'en ont pas
UPDATE public.vendors
SET shop_slug = generate_shop_slug(business_name, id)
WHERE shop_slug IS NULL OR shop_slug = '';

-- 2. Vérifier et afficher le résultat
DO $$
DECLARE
  total_vendors INTEGER;
  vendors_with_slug INTEGER;
  vendors_without_slug INTEGER;
  sample_slugs TEXT;
BEGIN
  -- Compter tous les vendeurs
  SELECT COUNT(*) INTO total_vendors FROM vendors;
  
  -- Compter ceux avec slug
  SELECT COUNT(*) INTO vendors_with_slug FROM vendors WHERE shop_slug IS NOT NULL AND shop_slug != '';
  
  -- Compter ceux sans slug
  SELECT COUNT(*) INTO vendors_without_slug FROM vendors WHERE shop_slug IS NULL OR shop_slug = '';
  
  -- Récupérer quelques exemples de slugs
  SELECT string_agg(business_name || ' → ' || shop_slug, E'\n     ')
  INTO sample_slugs
  FROM (
    SELECT business_name, shop_slug 
    FROM vendors 
    WHERE shop_slug IS NOT NULL 
    LIMIT 5
  ) sample;
  
  -- Afficher le résultat
  RAISE NOTICE '================================================';
  RAISE NOTICE '✅ MIGRATION SLUGS BOUTIQUES COMPLÉTÉE';
  RAISE NOTICE '================================================';
  RAISE NOTICE '📊 Total vendeurs: %', total_vendors;
  RAISE NOTICE '✅ Avec slug: % (%.1f%%)', vendors_with_slug, (vendors_with_slug::DECIMAL / NULLIF(total_vendors, 0) * 100);
  RAISE NOTICE '❌ Sans slug: %', vendors_without_slug;
  RAISE NOTICE '';
  RAISE NOTICE '📝 Exemples de slugs générés:';
  RAISE NOTICE '     %', sample_slugs;
  RAISE NOTICE '================================================';
  
  -- Avertir si certains vendeurs n'ont toujours pas de slug
  IF vendors_without_slug > 0 THEN
    RAISE WARNING '⚠️ % vendeurs n''ont toujours pas de slug!', vendors_without_slug;
    RAISE WARNING 'Vérifier les business_name NULL ou vides';
  ELSE
    RAISE NOTICE '🎉 TOUS LES VENDEURS ONT UN SLUG!';
  END IF;
  
  RAISE NOTICE '================================================';
END $$;

-- 3. Créer un index si inexistant (pour performance)
CREATE INDEX IF NOT EXISTS idx_vendors_shop_slug ON public.vendors(shop_slug);

-- 4. Ajouter une contrainte NOT NULL sur shop_slug pour les nouveaux vendeurs
-- (Seulement si TOUS les vendeurs ont maintenant un slug)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM vendors WHERE shop_slug IS NULL OR shop_slug = ''
  ) THEN
    -- Tous les vendeurs ont un slug, on peut ajouter la contrainte
    ALTER TABLE public.vendors 
    ALTER COLUMN shop_slug SET NOT NULL;
    
    RAISE NOTICE '✅ Contrainte NOT NULL ajoutée sur shop_slug';
  ELSE
    RAISE WARNING '⚠️ Contrainte NOT NULL non ajoutée (certains slugs manquants)';
  END IF;
END $$;

-- 5. Fonction pour régénérer un slug en cas de problème
CREATE OR REPLACE FUNCTION public.regenerate_shop_slug(vendor_id_param UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_business_name TEXT;
  v_new_slug TEXT;
BEGIN
  -- Récupérer le nom de la boutique
  SELECT business_name INTO v_business_name
  FROM vendors
  WHERE id = vendor_id_param;
  
  IF v_business_name IS NULL THEN
    RAISE EXCEPTION 'Vendeur % non trouvé', vendor_id_param;
  END IF;
  
  -- Générer un nouveau slug
  v_new_slug := generate_shop_slug(v_business_name, vendor_id_param);
  
  -- Mettre à jour le vendeur
  UPDATE vendors
  SET shop_slug = v_new_slug
  WHERE id = vendor_id_param;
  
  RAISE NOTICE 'Slug régénéré pour %: %', v_business_name, v_new_slug;
  
  RETURN v_new_slug;
END;
$$;

-- 6. Commentaire sur la fonction
COMMENT ON FUNCTION public.regenerate_shop_slug(UUID) IS 'Régénère le slug d''une boutique en cas de problème ou changement de nom';

-- ===================================================
-- FIN MIGRATION
-- ===================================================
