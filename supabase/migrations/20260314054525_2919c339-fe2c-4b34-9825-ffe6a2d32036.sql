-- Add customer_user_id to restaurant_orders for tracking by authenticated users
ALTER TABLE public.restaurant_orders 
ADD COLUMN IF NOT EXISTS customer_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL;

-- Index for fast lookups
CREATE INDEX IF NOT EXISTS idx_restaurant_orders_customer_user_id 
ON public.restaurant_orders(customer_user_id) WHERE customer_user_id IS NOT NULL;

-- RLS policy for customers to read their own orders
CREATE POLICY "Customers can view their own restaurant orders"
ON public.restaurant_orders
FOR SELECT
TO authenticated
USING (customer_user_id = auth.uid());