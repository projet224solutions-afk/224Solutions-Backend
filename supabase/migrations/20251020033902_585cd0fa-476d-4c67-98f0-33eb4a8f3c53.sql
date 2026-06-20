-- Corriger les fonctions avec search_path immutable

-- Supprimer le trigger en premier
DROP TRIGGER IF EXISTS trigger_update_badges_updated_at ON public.badges;

-- Supprimer la fonction
DROP FUNCTION IF EXISTS public.update_badges_updated_at();

-- Recréer la fonction avec SET search_path
CREATE OR REPLACE FUNCTION public.update_badges_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public;

-- Recréer le trigger
CREATE TRIGGER trigger_update_badges_updated_at
BEFORE UPDATE ON public.badges
FOR EACH ROW
EXECUTE FUNCTION public.update_badges_updated_at();