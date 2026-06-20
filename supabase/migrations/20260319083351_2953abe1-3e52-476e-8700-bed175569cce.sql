-- Trigger to auto-increment views_count (same RLS issue as sales_count)
CREATE OR REPLACE FUNCTION public.increment_digital_product_views(p_product_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE digital_products
  SET views_count = COALESCE(views_count, 0) + 1
  WHERE id = p_product_id;
END;
$$;

-- Grant execute to authenticated users
GRANT EXECUTE ON FUNCTION public.increment_digital_product_views(uuid) TO authenticated;