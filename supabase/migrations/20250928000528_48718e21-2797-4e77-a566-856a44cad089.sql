-- Fix security warnings by setting search_path on functions

-- Update generate_order_number function
CREATE OR REPLACE FUNCTION public.generate_order_number()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  -- Generate order number like ORD-YYYY-XXXXXX
  NEW.order_number = 'ORD-' || EXTRACT(YEAR FROM NOW()) || '-' || 
                     LPAD(nextval('order_number_seq')::text, 6, '0');
  RETURN NEW;
END;
$$;

-- Update update_vendor_rating function
CREATE OR REPLACE FUNCTION public.update_vendor_rating()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  vendor_id_to_update UUID;
  new_rating DECIMAL(3,2);
  review_count INTEGER;
BEGIN
  -- Get vendor_id from the review
  vendor_id_to_update := NEW.vendor_id;
  
  IF vendor_id_to_update IS NOT NULL THEN
    -- Calculate new average rating and count
    SELECT 
      AVG(rating)::DECIMAL(3,2),
      COUNT(*)
    INTO new_rating, review_count
    FROM public.reviews 
    WHERE vendor_id = vendor_id_to_update;
    
    -- Update vendor rating
    UPDATE public.vendors 
    SET 
      rating = COALESCE(new_rating, 0),
      total_reviews = review_count
    WHERE id = vendor_id_to_update;
  END IF;
  
  RETURN NEW;
END;
$$;

-- Update update_driver_rating function
CREATE OR REPLACE FUNCTION public.update_driver_rating()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  driver_id_to_update UUID;
  new_rating DECIMAL(3,2);
  delivery_count INTEGER;
BEGIN
  -- Get driver_id from the review
  driver_id_to_update := NEW.driver_id;
  
  IF driver_id_to_update IS NOT NULL THEN
    -- Calculate new average rating from reviews
    SELECT 
      AVG(rating)::DECIMAL(3,2)
    INTO new_rating
    FROM public.reviews 
    WHERE driver_id = driver_id_to_update;
    
    -- Get total deliveries count
    SELECT COUNT(*)
    INTO delivery_count
    FROM public.deliveries 
    WHERE driver_id = driver_id_to_update 
    AND status = 'delivered';
    
    -- Update driver rating
    UPDATE public.drivers 
    SET 
      rating = COALESCE(new_rating, 0),
      total_deliveries = delivery_count
    WHERE id = driver_id_to_update;
  END IF;
  
  RETURN NEW;
END;
$$;

-- Update update_inventory_on_order function
CREATE OR REPLACE FUNCTION public.update_inventory_on_order()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  -- Reserve inventory when order is created
  IF TG_OP = 'INSERT' THEN
    UPDATE public.inventory 
    SET reserved_quantity = reserved_quantity + NEW.quantity
    WHERE product_id = NEW.product_id 
    AND (variant_id = NEW.variant_id OR (variant_id IS NULL AND NEW.variant_id IS NULL));
  END IF;
  
  RETURN NEW;
END;
$$;