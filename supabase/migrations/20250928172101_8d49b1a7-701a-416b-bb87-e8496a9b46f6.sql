-- Create roles table
CREATE TABLE public.roles (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  name VARCHAR NOT NULL UNIQUE,
  description TEXT,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Create permissions table
CREATE TABLE public.permissions (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  role_id UUID NOT NULL REFERENCES public.roles(id) ON DELETE CASCADE,
  action VARCHAR NOT NULL,
  allowed BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(role_id, action)
);

-- Create agents table
CREATE TABLE public.agents (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  seller_id UUID NOT NULL,
  user_id UUID NOT NULL,
  role_id UUID NOT NULL REFERENCES public.roles(id) ON DELETE RESTRICT,
  status VARCHAR NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(seller_id, user_id)
);

-- Create warehouse_stocks table
CREATE TABLE public.warehouse_stocks (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  warehouse_id UUID NOT NULL REFERENCES public.warehouses(id) ON DELETE CASCADE,
  product_id UUID NOT NULL,
  quantity NUMERIC NOT NULL DEFAULT 0,
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(warehouse_id, product_id)
);

-- Create stock_movements table
CREATE TABLE public.stock_movements (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  product_id UUID NOT NULL,
  from_warehouse_id UUID REFERENCES public.warehouses(id),
  to_warehouse_id UUID REFERENCES public.warehouses(id),
  quantity NUMERIC NOT NULL,
  movement_type VARCHAR NOT NULL CHECK (movement_type IN ('in', 'out', 'transfer')),
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  notes TEXT
);

-- Enable Row Level Security
ALTER TABLE public.roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.warehouse_stocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_movements ENABLE ROW LEVEL SECURITY;

-- RLS Policies for roles
CREATE POLICY "Vendors can view all roles" ON public.roles
FOR SELECT USING (true);

-- RLS Policies for permissions
CREATE POLICY "Vendors can view all permissions" ON public.permissions
FOR SELECT USING (true);

-- RLS Policies for agents
CREATE POLICY "Vendors can manage their agents" ON public.agents
FOR ALL USING (auth.uid() = seller_id);

-- RLS Policies for warehouse_stocks
CREATE POLICY "Vendors can manage their warehouse stocks" ON public.warehouse_stocks
FOR ALL USING (EXISTS (
  SELECT 1 FROM public.warehouses w 
  WHERE w.id = warehouse_stocks.warehouse_id 
  AND w.vendor_id = auth.uid()
));

-- RLS Policies for stock_movements
CREATE POLICY "Vendors can view their stock movements" ON public.stock_movements
FOR SELECT USING (
  (from_warehouse_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.warehouses w 
    WHERE w.id = stock_movements.from_warehouse_id 
    AND w.vendor_id = auth.uid()
  )) OR
  (to_warehouse_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.warehouses w 
    WHERE w.id = stock_movements.to_warehouse_id 
    AND w.vendor_id = auth.uid()
  ))
);

CREATE POLICY "Vendors can create stock movements for their warehouses" ON public.stock_movements
FOR INSERT WITH CHECK (
  (from_warehouse_id IS NULL OR EXISTS (
    SELECT 1 FROM public.warehouses w 
    WHERE w.id = stock_movements.from_warehouse_id 
    AND w.vendor_id = auth.uid()
  )) AND
  (to_warehouse_id IS NULL OR EXISTS (
    SELECT 1 FROM public.warehouses w 
    WHERE w.id = stock_movements.to_warehouse_id 
    AND w.vendor_id = auth.uid()
  ))
);

-- Insert default roles
INSERT INTO public.roles (name, description) VALUES 
('admin', 'Administrateur avec tous les droits'),
('caissier', 'Caissier POS - gestion des paiements uniquement'),
('vendeur', 'Vendeur - gestion des produits et commandes'),
('gestionnaire_entrepot', 'Gestionnaire d''entrepôt - gestion des stocks');

-- Insert default permissions for each role
INSERT INTO public.permissions (role_id, action, allowed) 
SELECT r.id, action, allowed FROM public.roles r
CROSS JOIN (VALUES 
  -- Admin permissions (all allowed)
  ('admin', 'create_order', true),
  ('admin', 'update_stock', true),
  ('admin', 'validate_payment', true),
  ('admin', 'manage_products', true),
  ('admin', 'manage_agents', true),
  ('admin', 'manage_warehouses', true),
  ('admin', 'view_analytics', true),
  
  -- Caissier permissions
  ('caissier', 'create_order', true),
  ('caissier', 'update_stock', false),
  ('caissier', 'validate_payment', true),
  ('caissier', 'manage_products', false),
  ('caissier', 'manage_agents', false),
  ('caissier', 'manage_warehouses', false),
  ('caissier', 'view_analytics', false),
  
  -- Vendeur permissions
  ('vendeur', 'create_order', true),
  ('vendeur', 'update_stock', true),
  ('vendeur', 'validate_payment', false),
  ('vendeur', 'manage_products', true),
  ('vendeur', 'manage_agents', false),
  ('vendeur', 'manage_warehouses', false),
  ('vendeur', 'view_analytics', true),
  
  -- Gestionnaire entrepot permissions
  ('gestionnaire_entrepot', 'create_order', false),
  ('gestionnaire_entrepot', 'update_stock', true),
  ('gestionnaire_entrepot', 'validate_payment', false),
  ('gestionnaire_entrepot', 'manage_products', false),
  ('gestionnaire_entrepot', 'manage_agents', false),
  ('gestionnaire_entrepot', 'manage_warehouses', true),
  ('gestionnaire_entrepot', 'view_analytics', false)
) AS perms(role_name, action, allowed)
WHERE r.name = perms.role_name;

-- Create trigger to update warehouse_stocks updated_at
CREATE TRIGGER update_warehouse_stocks_updated_at
  BEFORE UPDATE ON public.warehouse_stocks
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();