-- Supprimer l'ancien trigger sur profiles
DROP TRIGGER IF EXISTS create_pos_settings_on_vendor_profile ON public.profiles;

-- Modifier la fonction pour ne plus chercher company_name sur profiles
CREATE OR REPLACE FUNCTION public.create_default_pos_settings()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_business_name TEXT;
BEGIN
  -- Si le trigger est sur vendors, utiliser business_name
  -- Sinon utiliser une valeur par défaut
  v_business_name := COALESCE(
    TG_TABLE_NAME = 'vendors' AND NEW.business_name IS NOT NULL,
    'Mon Commerce'
  )::TEXT;
  
  IF TG_TABLE_NAME = 'vendors' THEN
    v_business_name := COALESCE(NEW.business_name, 'Mon Commerce');
  ELSE
    v_business_name := 'Mon Commerce';
  END IF;

  INSERT INTO public.pos_settings (vendor_id, company_name)
  VALUES (
    CASE 
      WHEN TG_TABLE_NAME = 'vendors' THEN NEW.user_id
      ELSE NEW.id
    END,
    v_business_name
  )
  ON CONFLICT (vendor_id) DO NOTHING;
  
  RETURN NEW;
END;
$$;

-- Créer un nouveau trigger sur la table vendors (plus logique)
CREATE TRIGGER create_pos_settings_on_vendor
AFTER INSERT ON public.vendors
FOR EACH ROW
EXECUTE FUNCTION create_default_pos_settings();