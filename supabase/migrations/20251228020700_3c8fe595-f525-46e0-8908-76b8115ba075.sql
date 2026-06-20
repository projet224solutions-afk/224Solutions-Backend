-- Corriger le search_path de la fonction de trigger
CREATE OR REPLACE FUNCTION public.update_sales_updated_at()
RETURNS TRIGGER 
SECURITY INVOKER
SET search_path = public
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;