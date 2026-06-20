-- Corriger la fonction create_default_pos_settings
CREATE OR REPLACE FUNCTION public.create_default_pos_settings()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_business_name TEXT;
BEGIN
  -- Utiliser le nom de l'entreprise depuis le nouveau vendeur créé
  v_business_name := COALESCE(NEW.business_name, 'Mon Commerce');

  -- Insérer les paramètres POS pour ce vendeur
  INSERT INTO public.pos_settings (vendor_id, company_name)
  VALUES (NEW.user_id, v_business_name)
  ON CONFLICT (vendor_id) DO NOTHING;
  
  RETURN NEW;
END;
$$;