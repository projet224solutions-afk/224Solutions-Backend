-- Create function to automatically create profile when user signs up
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id, email, first_name, last_name, role)
  VALUES (
    new.id,
    new.email,
    new.raw_user_meta_data ->> 'first_name',
    new.raw_user_meta_data ->> 'last_name',
    COALESCE((new.raw_user_meta_data ->> 'role')::user_role, 'client')
  );
  RETURN new;
END;
$$;

-- Create trigger to automatically create profile
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE PROCEDURE public.handle_new_user();

-- Create function to update updated_at timestamp
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public;

-- Create triggers for updated_at on relevant tables
CREATE TRIGGER update_profiles_updated_at
    BEFORE UPDATE ON public.profiles
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_categories_updated_at
    BEFORE UPDATE ON public.categories
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_vendors_updated_at
    BEFORE UPDATE ON public.vendors
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_products_updated_at
    BEFORE UPDATE ON public.products
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_customers_updated_at
    BEFORE UPDATE ON public.customers
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_orders_updated_at
    BEFORE UPDATE ON public.orders
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_carts_updated_at
    BEFORE UPDATE ON public.carts
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_deliveries_updated_at
    BEFORE UPDATE ON public.deliveries
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_drivers_updated_at
    BEFORE UPDATE ON public.drivers
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_rides_updated_at
    BEFORE UPDATE ON public.rides
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_syndicat_badges_updated_at
    BEFORE UPDATE ON public.syndicat_badges
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_international_shipments_updated_at
    BEFORE UPDATE ON public.international_shipments
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_promotions_updated_at
    BEFORE UPDATE ON public.promotions
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at_column();

-- Create function to generate order numbers
CREATE OR REPLACE FUNCTION public.generate_order_number()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  -- Generate order number like ORD-YYYY-XXXXXX
  NEW.order_number = 'ORD-' || EXTRACT(YEAR FROM NOW()) || '-' || 
                     LPAD(nextval('order_number_seq')::text, 6, '0');
  RETURN NEW;
END;
$$;

-- Create sequence for order numbers
CREATE SEQUENCE IF NOT EXISTS order_number_seq START 1;

-- Create trigger for order number generation
CREATE TRIGGER generate_order_number_trigger
  BEFORE INSERT ON public.orders
  FOR EACH ROW
  WHEN (NEW.order_number IS NULL)
  EXECUTE FUNCTION public.generate_order_number();

-- Create function to update vendor ratings
CREATE OR REPLACE FUNCTION public.update_vendor_rating()
RETURNS trigger
LANGUAGE plpgsql
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

-- Create trigger to update vendor ratings when reviews are added
CREATE TRIGGER update_vendor_rating_trigger
  AFTER INSERT OR UPDATE ON public.reviews
  FOR EACH ROW
  WHEN (NEW.vendor_id IS NOT NULL)
  EXECUTE FUNCTION public.update_vendor_rating();

-- Create function to update driver ratings
CREATE OR REPLACE FUNCTION public.update_driver_rating()
RETURNS trigger
LANGUAGE plpgsql
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

-- Create trigger to update driver ratings
CREATE TRIGGER update_driver_rating_trigger
  AFTER INSERT OR UPDATE ON public.reviews
  FOR EACH ROW
  WHEN (NEW.driver_id IS NOT NULL)
  EXECUTE FUNCTION public.update_driver_rating();

-- Create function to update inventory when order is created
CREATE OR REPLACE FUNCTION public.update_inventory_on_order()
RETURNS trigger
LANGUAGE plpgsql
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

-- Create trigger to update inventory on order items
CREATE TRIGGER update_inventory_on_order_trigger
  AFTER INSERT ON public.order_items
  FOR EACH ROW
  EXECUTE FUNCTION public.update_inventory_on_order();

-- Enable realtime for important tables
ALTER PUBLICATION supabase_realtime ADD TABLE public.orders;
ALTER PUBLICATION supabase_realtime ADD TABLE public.deliveries;
ALTER PUBLICATION supabase_realtime ADD TABLE public.rides;
ALTER PUBLICATION supabase_realtime ADD TABLE public.messages;

-- Set replica identity for realtime tables
ALTER TABLE public.orders REPLICA IDENTITY FULL;
ALTER TABLE public.deliveries REPLICA IDENTITY FULL;
ALTER TABLE public.rides REPLICA IDENTITY FULL;
ALTER TABLE public.messages REPLICA IDENTITY FULL;