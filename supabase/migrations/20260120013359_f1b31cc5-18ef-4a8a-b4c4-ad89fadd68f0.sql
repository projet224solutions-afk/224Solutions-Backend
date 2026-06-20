-- Table de liaison fournisseur-produits pour stocker les produits associés à chaque fournisseur
CREATE TABLE public.vendor_supplier_products (
    id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    supplier_id UUID NOT NULL REFERENCES public.vendor_suppliers(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
    unit_cost NUMERIC(12, 2) DEFAULT 0,
    default_quantity INTEGER DEFAULT 1,
    notes TEXT,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
    UNIQUE(supplier_id, product_id)
);

-- Enable RLS
ALTER TABLE public.vendor_supplier_products ENABLE ROW LEVEL SECURITY;

-- Policies: vendors can manage supplier products linked to their suppliers
CREATE POLICY "Vendors can view their supplier products"
ON public.vendor_supplier_products
FOR SELECT
USING (
    EXISTS (
        SELECT 1 FROM public.vendor_suppliers vs
        JOIN public.vendors v ON v.id = vs.vendor_id
        WHERE vs.id = vendor_supplier_products.supplier_id
        AND v.user_id = auth.uid()
    )
);

CREATE POLICY "Vendors can insert their supplier products"
ON public.vendor_supplier_products
FOR INSERT
WITH CHECK (
    EXISTS (
        SELECT 1 FROM public.vendor_suppliers vs
        JOIN public.vendors v ON v.id = vs.vendor_id
        WHERE vs.id = vendor_supplier_products.supplier_id
        AND v.user_id = auth.uid()
    )
);

CREATE POLICY "Vendors can update their supplier products"
ON public.vendor_supplier_products
FOR UPDATE
USING (
    EXISTS (
        SELECT 1 FROM public.vendor_suppliers vs
        JOIN public.vendors v ON v.id = vs.vendor_id
        WHERE vs.id = vendor_supplier_products.supplier_id
        AND v.user_id = auth.uid()
    )
);

CREATE POLICY "Vendors can delete their supplier products"
ON public.vendor_supplier_products
FOR DELETE
USING (
    EXISTS (
        SELECT 1 FROM public.vendor_suppliers vs
        JOIN public.vendors v ON v.id = vs.vendor_id
        WHERE vs.id = vendor_supplier_products.supplier_id
        AND v.user_id = auth.uid()
    )
);

-- Trigger for updated_at
CREATE TRIGGER update_vendor_supplier_products_updated_at
BEFORE UPDATE ON public.vendor_supplier_products
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

-- Index pour améliorer les performances
CREATE INDEX idx_vendor_supplier_products_supplier_id ON public.vendor_supplier_products(supplier_id);
CREATE INDEX idx_vendor_supplier_products_product_id ON public.vendor_supplier_products(product_id);