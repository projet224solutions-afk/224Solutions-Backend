-- Créer pos_sales si manquante + stock_synced
CREATE TABLE IF NOT EXISTS public.pos_sales (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id uuid NOT NULL,
  local_sale_id text NOT NULL,
  total_amount numeric NOT NULL DEFAULT 0,
  discount_total numeric DEFAULT 0,
  payment_method text NOT NULL,
  customer_name text,
  customer_phone text,
  notes text,
  sold_at timestamptz NOT NULL,
  synced_at timestamptz DEFAULT now(),
  status text DEFAULT 'completed',
  stock_synced boolean DEFAULT true,
  created_at timestamptz DEFAULT now()
);

ALTER TABLE public.pos_sales ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Service role only" ON public.pos_sales
  FOR ALL USING (false);

CREATE UNIQUE INDEX IF NOT EXISTS idx_pos_sales_vendor_local
  ON public.pos_sales(vendor_id, local_sale_id);

-- pos_sale_items
CREATE TABLE IF NOT EXISTS public.pos_sale_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pos_sale_id uuid NOT NULL REFERENCES public.pos_sales(id) ON DELETE CASCADE,
  product_id uuid NOT NULL,
  product_name text NOT NULL,
  quantity integer NOT NULL,
  unit_price numeric NOT NULL,
  discount numeric DEFAULT 0,
  total_price numeric NOT NULL,
  created_at timestamptz DEFAULT now()
);

ALTER TABLE public.pos_sale_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Service role only" ON public.pos_sale_items
  FOR ALL USING (false);