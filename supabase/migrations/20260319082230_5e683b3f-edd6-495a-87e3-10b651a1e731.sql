-- Trigger to auto-increment sales_count on digital_products when a purchase is created
CREATE OR REPLACE FUNCTION public.increment_digital_product_sales()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.payment_status = 'completed' THEN
    UPDATE digital_products
    SET sales_count = COALESCE(sales_count, 0) + 1
    WHERE id = NEW.product_id;
  END IF;
  RETURN NEW;
END;
$$;

-- Drop if exists and recreate
DROP TRIGGER IF EXISTS trg_increment_digital_sales ON digital_product_purchases;
CREATE TRIGGER trg_increment_digital_sales
  AFTER INSERT ON digital_product_purchases
  FOR EACH ROW
  EXECUTE FUNCTION increment_digital_product_sales();

-- Also handle status updates (e.g. if payment_status is set to completed after insert)
CREATE OR REPLACE FUNCTION public.increment_digital_product_sales_on_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.payment_status = 'completed' AND (OLD.payment_status IS NULL OR OLD.payment_status != 'completed') THEN
    UPDATE digital_products
    SET sales_count = COALESCE(sales_count, 0) + 1
    WHERE id = NEW.product_id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_increment_digital_sales_on_update ON digital_product_purchases;
CREATE TRIGGER trg_increment_digital_sales_on_update
  AFTER UPDATE ON digital_product_purchases
  FOR EACH ROW
  EXECUTE FUNCTION increment_digital_product_sales_on_update();