-- Fix RLS for vendor_supplier_products to allow agents access
-- Drop existing SELECT policy
DROP POLICY IF EXISTS "Vendors can view their supplier products" ON public.vendor_supplier_products;

-- Create new SELECT policy using is_vendor_or_agent
CREATE POLICY "Vendors and agents can view supplier products"
ON public.vendor_supplier_products
FOR SELECT
USING (
    EXISTS (
        SELECT 1 FROM public.vendor_suppliers vs
        WHERE vs.id = vendor_supplier_products.supplier_id
        AND is_vendor_or_agent(vs.vendor_id)
    )
);

-- Also fix UPDATE policy
DROP POLICY IF EXISTS "Vendors can update their supplier products" ON public.vendor_supplier_products;

CREATE POLICY "Vendors and agents can update supplier products"
ON public.vendor_supplier_products
FOR UPDATE
USING (
    EXISTS (
        SELECT 1 FROM public.vendor_suppliers vs
        WHERE vs.id = vendor_supplier_products.supplier_id
        AND is_vendor_or_agent(vs.vendor_id)
    )
);

-- Also fix INSERT policy
DROP POLICY IF EXISTS "Vendors can insert their supplier products" ON public.vendor_supplier_products;

CREATE POLICY "Vendors and agents can insert supplier products"
ON public.vendor_supplier_products
FOR INSERT
WITH CHECK (
    EXISTS (
        SELECT 1 FROM public.vendor_suppliers vs
        WHERE vs.id = vendor_supplier_products.supplier_id
        AND is_vendor_or_agent(vs.vendor_id)
    )
);

-- Also fix DELETE policy
DROP POLICY IF EXISTS "Vendors can delete their supplier products" ON public.vendor_supplier_products;

CREATE POLICY "Vendors and agents can delete supplier products"
ON public.vendor_supplier_products
FOR DELETE
USING (
    EXISTS (
        SELECT 1 FROM public.vendor_suppliers vs
        WHERE vs.id = vendor_supplier_products.supplier_id
        AND is_vendor_or_agent(vs.vendor_id)
    )
);