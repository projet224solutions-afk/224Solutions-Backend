-- Supprimer l'ancienne politique qui cause la récursion
DROP POLICY IF EXISTS "Vendors can view their customers through orders" ON public.customers;

-- Créer une fonction security definer pour éviter la récursion
CREATE OR REPLACE FUNCTION public.can_vendor_view_customer(_vendor_user_id uuid, _customer_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.orders o
    INNER JOIN public.vendors v ON o.vendor_id = v.id
    WHERE o.customer_id = _customer_id
    AND v.user_id = _vendor_user_id
  );
$$;

-- Créer une nouvelle politique utilisant la fonction
CREATE POLICY "Vendors can view their customers through orders"
ON public.customers
FOR SELECT
USING (
  public.can_vendor_view_customer(auth.uid(), customers.id)
);