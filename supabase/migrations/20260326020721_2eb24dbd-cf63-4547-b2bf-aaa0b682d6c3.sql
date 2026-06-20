-- Trigger to enforce product limit on insert based on subscription plan
CREATE OR REPLACE FUNCTION public.enforce_product_limit()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
  v_max_products int;
  v_current_count int;
  v_plan_name text;
BEGIN
  -- Get the vendor's user_id
  SELECT user_id INTO v_user_id FROM vendors WHERE id = NEW.vendor_id;
  
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Vendeur introuvable';
  END IF;

  -- Get active subscription plan limits
  SELECT p.max_products, p.name INTO v_max_products, v_plan_name
  FROM subscriptions s
  JOIN plans p ON p.id = s.plan_id
  WHERE s.user_id = v_user_id
    AND s.status = 'active'
    AND (s.current_period_end IS NULL OR s.current_period_end > now())
  ORDER BY s.created_at DESC
  LIMIT 1;

  -- No subscription = free plan defaults
  IF v_max_products IS NULL AND v_plan_name IS NULL THEN
    SELECT p.max_products INTO v_max_products
    FROM plans p WHERE p.name = 'free' AND p.is_active = true LIMIT 1;
  END IF;

  -- NULL max_products means unlimited
  IF v_max_products IS NULL THEN
    RETURN NEW;
  END IF;

  -- Count current products
  SELECT count(*) INTO v_current_count
  FROM products
  WHERE vendor_id = NEW.vendor_id;

  IF v_current_count >= v_max_products THEN
    RAISE EXCEPTION 'Limite de produits atteinte (% / %). Mettez à niveau votre plan.', v_current_count, v_max_products;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_product_limit ON products;
CREATE TRIGGER trg_enforce_product_limit
  BEFORE INSERT ON products
  FOR EACH ROW
  EXECUTE FUNCTION enforce_product_limit();