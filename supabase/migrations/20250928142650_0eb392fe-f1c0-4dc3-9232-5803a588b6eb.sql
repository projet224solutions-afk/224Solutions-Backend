-- Corriger les fonctions avec search_path pour la sécurité
CREATE OR REPLACE FUNCTION public.create_default_pos_settings()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.pos_settings (vendor_id, company_name)
  VALUES (NEW.id, COALESCE(NEW.company_name, 'Mon Commerce'))
  ON CONFLICT (vendor_id) DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;