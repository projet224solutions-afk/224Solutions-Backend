-- Ajouter colonne slug aux vendors
ALTER TABLE public.vendors ADD COLUMN IF NOT EXISTS shop_slug VARCHAR(100) UNIQUE;

-- Index pour recherche rapide par slug
CREATE INDEX IF NOT EXISTS idx_vendors_shop_slug ON public.vendors(shop_slug);

-- Fonction pour générer un slug à partir du nom de la boutique
CREATE OR REPLACE FUNCTION public.generate_shop_slug(business_name TEXT, vendor_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  base_slug TEXT;
  final_slug TEXT;
  counter INTEGER := 0;
  slug_exists BOOLEAN;
BEGIN
  -- Convertir le nom en slug: lowercase, remplacer espaces par tirets, supprimer caractères spéciaux
  base_slug := lower(trim(business_name));
  base_slug := regexp_replace(base_slug, '[àáâãäå]', 'a', 'gi');
  base_slug := regexp_replace(base_slug, '[èéêë]', 'e', 'gi');
  base_slug := regexp_replace(base_slug, '[ìíîï]', 'i', 'gi');
  base_slug := regexp_replace(base_slug, '[òóôõö]', 'o', 'gi');
  base_slug := regexp_replace(base_slug, '[ùúûü]', 'u', 'gi');
  base_slug := regexp_replace(base_slug, '[ñ]', 'n', 'gi');
  base_slug := regexp_replace(base_slug, '[ç]', 'c', 'gi');
  base_slug := regexp_replace(base_slug, '[^a-z0-9\s-]', '', 'gi');
  base_slug := regexp_replace(base_slug, '\s+', '-', 'g');
  base_slug := regexp_replace(base_slug, '-+', '-', 'g');
  base_slug := trim(both '-' from base_slug);
  
  -- Si le slug est vide, utiliser 'boutique'
  IF base_slug = '' OR base_slug IS NULL THEN
    base_slug := 'boutique';
  END IF;
  
  -- Limiter à 80 caractères
  base_slug := substring(base_slug from 1 for 80);
  
  final_slug := base_slug;
  
  -- Vérifier l'unicité et ajouter un suffix si nécessaire
  LOOP
    SELECT EXISTS(
      SELECT 1 FROM vendors 
      WHERE shop_slug = final_slug 
      AND id != COALESCE(vendor_id, '00000000-0000-0000-0000-000000000000'::uuid)
    ) INTO slug_exists;
    
    IF NOT slug_exists THEN
      EXIT;
    END IF;
    
    counter := counter + 1;
    final_slug := base_slug || '-' || counter::text;
  END LOOP;
  
  RETURN final_slug;
END;
$$;

-- Trigger pour générer automatiquement le slug à l'insertion ou mise à jour
CREATE OR REPLACE FUNCTION public.trigger_generate_shop_slug()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  -- Générer le slug si non défini ou si le nom a changé
  IF NEW.shop_slug IS NULL OR 
     (TG_OP = 'UPDATE' AND OLD.business_name IS DISTINCT FROM NEW.business_name AND OLD.shop_slug = NEW.shop_slug) THEN
    NEW.shop_slug := generate_shop_slug(NEW.business_name, NEW.id);
  END IF;
  
  RETURN NEW;
END;
$$;

-- Supprimer le trigger s'il existe
DROP TRIGGER IF EXISTS trigger_vendor_shop_slug ON public.vendors;

-- Créer le trigger
CREATE TRIGGER trigger_vendor_shop_slug
  BEFORE INSERT OR UPDATE ON public.vendors
  FOR EACH ROW
  EXECUTE FUNCTION public.trigger_generate_shop_slug();

-- Générer les slugs pour les vendeurs existants qui n'en ont pas
UPDATE public.vendors
SET shop_slug = generate_shop_slug(business_name, id)
WHERE shop_slug IS NULL;