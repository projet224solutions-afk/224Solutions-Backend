
-- Trigger: auto-clear AI recommendations cache when products change
CREATE OR REPLACE FUNCTION public.invalidate_ai_recommendations_cache()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Delete all cached recommendations (they reference product IDs that may have changed)
  DELETE FROM public.ai_recommendations_cache
  WHERE expires_at > now(); -- only delete still-valid cache entries
  
  RETURN COALESCE(NEW, OLD);
END;
$$;

-- Attach trigger to products table
DROP TRIGGER IF EXISTS trg_invalidate_ai_cache_on_product_change ON public.products;
CREATE TRIGGER trg_invalidate_ai_cache_on_product_change
  AFTER INSERT OR UPDATE OR DELETE ON public.products
  FOR EACH STATEMENT
  EXECUTE FUNCTION public.invalidate_ai_recommendations_cache();
