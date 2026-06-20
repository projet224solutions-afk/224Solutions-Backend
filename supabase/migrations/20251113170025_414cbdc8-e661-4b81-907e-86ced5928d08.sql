-- Fonction pour restaurer le stock lors de l'annulation
CREATE OR REPLACE FUNCTION public.increment_product_stock(
  p_product_id UUID,
  p_quantity INTEGER
)
RETURNS VOID
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE public.products
  SET stock_quantity = stock_quantity + p_quantity,
      updated_at = NOW()
  WHERE id = p_product_id;
END;
$$;

COMMENT ON FUNCTION public.increment_product_stock IS 'Incrémente le stock d''un produit (pour annulations)';