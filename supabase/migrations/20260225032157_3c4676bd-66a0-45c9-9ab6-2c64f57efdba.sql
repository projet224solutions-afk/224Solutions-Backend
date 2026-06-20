-- Add vendor_id column to wishlists for vendor favorites
ALTER TABLE public.wishlists 
  ALTER COLUMN product_id DROP NOT NULL,
  ADD COLUMN vendor_id UUID REFERENCES public.vendors(id) ON DELETE CASCADE;

-- Add constraint: at least one of product_id or vendor_id must be set
ALTER TABLE public.wishlists 
  ADD CONSTRAINT wishlists_product_or_vendor_check 
  CHECK (product_id IS NOT NULL OR vendor_id IS NOT NULL);

-- Add unique constraint to prevent duplicate vendor favorites
CREATE UNIQUE INDEX wishlists_user_vendor_unique ON public.wishlists(user_id, vendor_id) WHERE vendor_id IS NOT NULL;

-- Index for faster vendor favorites lookup
CREATE INDEX idx_wishlists_vendor_id ON public.wishlists(vendor_id) WHERE vendor_id IS NOT NULL;