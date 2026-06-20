-- ============================================
-- SYSTÈME RESTAURANT PROFESSIONNEL COMPLET
-- Inspiré des grands restaurants du monde
-- ============================================

-- 1. TABLE DES TABLES (gestion des places)
CREATE TABLE IF NOT EXISTS public.restaurant_tables (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  professional_service_id UUID NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  table_number TEXT NOT NULL,
  capacity INTEGER NOT NULL DEFAULT 4,
  location TEXT, -- 'intérieur', 'terrasse', 'salon privé', 'bar'
  shape TEXT DEFAULT 'rectangle', -- 'rectangle', 'round', 'square'
  status TEXT DEFAULT 'available', -- 'available', 'occupied', 'reserved', 'cleaning'
  current_order_id UUID,
  position_x INTEGER DEFAULT 0, -- Pour le plan de salle
  position_y INTEGER DEFAULT 0,
  is_active BOOLEAN DEFAULT true,
  qr_code_url TEXT, -- QR code pour commande sur table
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- 2. TABLE DES CATÉGORIES DE MENU
CREATE TABLE IF NOT EXISTS public.restaurant_menu_categories (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  professional_service_id UUID NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT,
  icon TEXT, -- emoji ou icône
  display_order INTEGER DEFAULT 0,
  is_active BOOLEAN DEFAULT true,
  available_from TIME, -- Disponibilité horaire (ex: petit-déj 7h-11h)
  available_until TIME,
  image_url TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- 3. TABLE DES PLATS (Menu items)
CREATE TABLE IF NOT EXISTS public.restaurant_menu_items (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  professional_service_id UUID NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  category_id UUID REFERENCES public.restaurant_menu_categories(id) ON DELETE SET NULL,
  name TEXT NOT NULL,
  description TEXT,
  price NUMERIC(10,2) NOT NULL DEFAULT 0,
  cost_price NUMERIC(10,2), -- Prix de revient
  image_url TEXT,
  preparation_time INTEGER DEFAULT 15, -- minutes
  calories INTEGER,
  allergens TEXT[], -- ['gluten', 'lactose', 'noix', etc.]
  dietary_tags TEXT[], -- ['végétarien', 'vegan', 'halal', 'casher', 'sans gluten']
  spicy_level INTEGER DEFAULT 0, -- 0-3
  is_available BOOLEAN DEFAULT true,
  is_featured BOOLEAN DEFAULT false, -- Plat signature
  is_new BOOLEAN DEFAULT false,
  display_order INTEGER DEFAULT 0,
  ingredients JSONB, -- Liste des ingrédients avec quantités
  variants JSONB, -- Tailles/options: [{"name": "Small", "price": 10}, ...]
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- 4. AMÉLIORATIONS TABLE COMMANDES EXISTANTE
ALTER TABLE public.restaurant_orders 
  ADD COLUMN IF NOT EXISTS order_number TEXT,
  ADD COLUMN IF NOT EXISTS delivery_address TEXT,
  ADD COLUMN IF NOT EXISTS delivery_instructions TEXT,
  ADD COLUMN IF NOT EXISTS payment_method TEXT DEFAULT 'cash',
  ADD COLUMN IF NOT EXISTS payment_status TEXT DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS discount_amount NUMERIC(10,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS tip_amount NUMERIC(10,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS assigned_staff_id UUID,
  ADD COLUMN IF NOT EXISTS kitchen_notes TEXT,
  ADD COLUMN IF NOT EXISTS started_preparing_at TIMESTAMP WITH TIME ZONE,
  ADD COLUMN IF NOT EXISTS ready_at TIMESTAMP WITH TIME ZONE,
  ADD COLUMN IF NOT EXISTS completed_at TIMESTAMP WITH TIME ZONE,
  ADD COLUMN IF NOT EXISTS cancelled_reason TEXT,
  ADD COLUMN IF NOT EXISTS source TEXT DEFAULT 'pos'; -- 'pos', 'online', 'qr_code', 'phone'

-- 5. TABLE DES LIGNES DE COMMANDE (détails)
CREATE TABLE IF NOT EXISTS public.restaurant_order_items (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  order_id UUID NOT NULL REFERENCES public.restaurant_orders(id) ON DELETE CASCADE,
  menu_item_id UUID REFERENCES public.restaurant_menu_items(id) ON DELETE SET NULL,
  name TEXT NOT NULL,
  quantity INTEGER NOT NULL DEFAULT 1,
  unit_price NUMERIC(10,2) NOT NULL,
  total_price NUMERIC(10,2) NOT NULL,
  variant_name TEXT, -- Taille choisie
  special_instructions TEXT, -- "Sans oignons", etc.
  status TEXT DEFAULT 'pending', -- 'pending', 'preparing', 'ready', 'served'
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- 6. AFFICHAGE CUISINE (Kitchen Display System)
CREATE TABLE IF NOT EXISTS public.restaurant_kitchen_orders (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  order_id UUID NOT NULL REFERENCES public.restaurant_orders(id) ON DELETE CASCADE,
  station TEXT, -- 'grill', 'friture', 'patisserie', 'bar', 'general'
  priority INTEGER DEFAULT 0, -- 0 = normal, 1 = urgent, 2 = VIP
  status TEXT DEFAULT 'pending', -- 'pending', 'in_progress', 'ready', 'served'
  assigned_chef_id UUID REFERENCES public.restaurant_staff(id) ON DELETE SET NULL,
  started_at TIMESTAMP WITH TIME ZONE,
  completed_at TIMESTAMP WITH TIME ZONE,
  estimated_time INTEGER, -- minutes
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- 7. PROGRAMME FIDÉLITÉ
CREATE TABLE IF NOT EXISTS public.restaurant_loyalty_points (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  professional_service_id UUID NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  customer_phone TEXT NOT NULL,
  customer_name TEXT,
  points_balance INTEGER DEFAULT 0,
  total_points_earned INTEGER DEFAULT 0,
  total_visits INTEGER DEFAULT 0,
  last_visit_at TIMESTAMP WITH TIME ZONE,
  tier TEXT DEFAULT 'bronze', -- 'bronze', 'silver', 'gold', 'platinum'
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- 8. HISTORIQUE DES POINTS
CREATE TABLE IF NOT EXISTS public.restaurant_loyalty_transactions (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  loyalty_id UUID NOT NULL REFERENCES public.restaurant_loyalty_points(id) ON DELETE CASCADE,
  order_id UUID REFERENCES public.restaurant_orders(id) ON DELETE SET NULL,
  points_change INTEGER NOT NULL,
  reason TEXT, -- 'purchase', 'redemption', 'bonus', 'expiry'
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- 9. ZONES DE LIVRAISON
CREATE TABLE IF NOT EXISTS public.restaurant_delivery_zones (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  professional_service_id UUID NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  zone_name TEXT NOT NULL,
  min_order_amount NUMERIC(10,2) DEFAULT 0,
  delivery_fee NUMERIC(10,2) DEFAULT 0,
  estimated_time INTEGER DEFAULT 30, -- minutes
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- 10. PARAMÈTRES DU RESTAURANT
CREATE TABLE IF NOT EXISTS public.restaurant_settings (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  professional_service_id UUID NOT NULL UNIQUE REFERENCES public.professional_services(id) ON DELETE CASCADE,
  currency TEXT DEFAULT 'GNF',
  tax_rate NUMERIC(5,2) DEFAULT 0,
  service_charge_rate NUMERIC(5,2) DEFAULT 0,
  accept_reservations BOOLEAN DEFAULT true,
  accept_takeaway BOOLEAN DEFAULT true,
  accept_delivery BOOLEAN DEFAULT true,
  accept_dine_in BOOLEAN DEFAULT true,
  min_reservation_advance INTEGER DEFAULT 60, -- minutes
  max_reservation_advance INTEGER DEFAULT 30, -- jours
  opening_hours JSONB, -- {"monday": {"open": "09:00", "close": "22:00"}, ...}
  preparation_time_buffer INTEGER DEFAULT 5, -- minutes supplémentaires
  auto_accept_orders BOOLEAN DEFAULT false,
  loyalty_points_per_unit NUMERIC(5,2) DEFAULT 1, -- Points par unité de devise
  loyalty_points_value NUMERIC(5,2) DEFAULT 100, -- Valeur en devise de 100 points
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Index pour performances
CREATE INDEX IF NOT EXISTS idx_restaurant_tables_service ON public.restaurant_tables(professional_service_id);
CREATE INDEX IF NOT EXISTS idx_restaurant_menu_categories_service ON public.restaurant_menu_categories(professional_service_id);
CREATE INDEX IF NOT EXISTS idx_restaurant_menu_items_service ON public.restaurant_menu_items(professional_service_id);
CREATE INDEX IF NOT EXISTS idx_restaurant_menu_items_category ON public.restaurant_menu_items(category_id);
CREATE INDEX IF NOT EXISTS idx_restaurant_order_items_order ON public.restaurant_order_items(order_id);
CREATE INDEX IF NOT EXISTS idx_restaurant_kitchen_orders_order ON public.restaurant_kitchen_orders(order_id);
CREATE INDEX IF NOT EXISTS idx_restaurant_loyalty_service ON public.restaurant_loyalty_points(professional_service_id);

-- Enable RLS
ALTER TABLE public.restaurant_tables ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.restaurant_menu_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.restaurant_menu_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.restaurant_order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.restaurant_kitchen_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.restaurant_loyalty_points ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.restaurant_loyalty_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.restaurant_delivery_zones ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.restaurant_settings ENABLE ROW LEVEL SECURITY;

-- RLS Policies pour restaurant_tables
CREATE POLICY "Users can view their restaurant tables" ON public.restaurant_tables
FOR SELECT USING (
  professional_service_id IN (SELECT id FROM public.professional_services WHERE user_id = auth.uid())
);
CREATE POLICY "Users can manage their restaurant tables" ON public.restaurant_tables
FOR ALL USING (
  professional_service_id IN (SELECT id FROM public.professional_services WHERE user_id = auth.uid())
);

-- RLS Policies pour restaurant_menu_categories
CREATE POLICY "Users can view their menu categories" ON public.restaurant_menu_categories
FOR SELECT USING (
  professional_service_id IN (SELECT id FROM public.professional_services WHERE user_id = auth.uid())
);
CREATE POLICY "Users can manage their menu categories" ON public.restaurant_menu_categories
FOR ALL USING (
  professional_service_id IN (SELECT id FROM public.professional_services WHERE user_id = auth.uid())
);

-- RLS Policies pour restaurant_menu_items
CREATE POLICY "Users can view their menu items" ON public.restaurant_menu_items
FOR SELECT USING (
  professional_service_id IN (SELECT id FROM public.professional_services WHERE user_id = auth.uid())
);
CREATE POLICY "Users can manage their menu items" ON public.restaurant_menu_items
FOR ALL USING (
  professional_service_id IN (SELECT id FROM public.professional_services WHERE user_id = auth.uid())
);

-- RLS Policies pour restaurant_order_items
CREATE POLICY "Users can view their order items" ON public.restaurant_order_items
FOR SELECT USING (
  order_id IN (SELECT id FROM public.restaurant_orders WHERE professional_service_id IN (SELECT id FROM public.professional_services WHERE user_id = auth.uid()))
);
CREATE POLICY "Users can manage their order items" ON public.restaurant_order_items
FOR ALL USING (
  order_id IN (SELECT id FROM public.restaurant_orders WHERE professional_service_id IN (SELECT id FROM public.professional_services WHERE user_id = auth.uid()))
);

-- RLS Policies pour restaurant_kitchen_orders
CREATE POLICY "Users can view their kitchen orders" ON public.restaurant_kitchen_orders
FOR SELECT USING (
  order_id IN (SELECT id FROM public.restaurant_orders WHERE professional_service_id IN (SELECT id FROM public.professional_services WHERE user_id = auth.uid()))
);
CREATE POLICY "Users can manage their kitchen orders" ON public.restaurant_kitchen_orders
FOR ALL USING (
  order_id IN (SELECT id FROM public.restaurant_orders WHERE professional_service_id IN (SELECT id FROM public.professional_services WHERE user_id = auth.uid()))
);

-- RLS Policies pour restaurant_loyalty_points
CREATE POLICY "Users can view their loyalty points" ON public.restaurant_loyalty_points
FOR SELECT USING (
  professional_service_id IN (SELECT id FROM public.professional_services WHERE user_id = auth.uid())
);
CREATE POLICY "Users can manage their loyalty points" ON public.restaurant_loyalty_points
FOR ALL USING (
  professional_service_id IN (SELECT id FROM public.professional_services WHERE user_id = auth.uid())
);

-- RLS Policies pour restaurant_loyalty_transactions
CREATE POLICY "Users can view their loyalty transactions" ON public.restaurant_loyalty_transactions
FOR SELECT USING (
  loyalty_id IN (SELECT id FROM public.restaurant_loyalty_points WHERE professional_service_id IN (SELECT id FROM public.professional_services WHERE user_id = auth.uid()))
);
CREATE POLICY "Users can manage their loyalty transactions" ON public.restaurant_loyalty_transactions
FOR ALL USING (
  loyalty_id IN (SELECT id FROM public.restaurant_loyalty_points WHERE professional_service_id IN (SELECT id FROM public.professional_services WHERE user_id = auth.uid()))
);

-- RLS Policies pour restaurant_delivery_zones
CREATE POLICY "Users can view their delivery zones" ON public.restaurant_delivery_zones
FOR SELECT USING (
  professional_service_id IN (SELECT id FROM public.professional_services WHERE user_id = auth.uid())
);
CREATE POLICY "Users can manage their delivery zones" ON public.restaurant_delivery_zones
FOR ALL USING (
  professional_service_id IN (SELECT id FROM public.professional_services WHERE user_id = auth.uid())
);

-- RLS Policies pour restaurant_settings
CREATE POLICY "Users can view their restaurant settings" ON public.restaurant_settings
FOR SELECT USING (
  professional_service_id IN (SELECT id FROM public.professional_services WHERE user_id = auth.uid())
);
CREATE POLICY "Users can manage their restaurant settings" ON public.restaurant_settings
FOR ALL USING (
  professional_service_id IN (SELECT id FROM public.professional_services WHERE user_id = auth.uid())
);

-- Trigger pour updated_at
CREATE OR REPLACE FUNCTION public.update_restaurant_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public;

CREATE TRIGGER update_restaurant_tables_updated_at BEFORE UPDATE ON public.restaurant_tables FOR EACH ROW EXECUTE FUNCTION public.update_restaurant_updated_at();
CREATE TRIGGER update_restaurant_menu_categories_updated_at BEFORE UPDATE ON public.restaurant_menu_categories FOR EACH ROW EXECUTE FUNCTION public.update_restaurant_updated_at();
CREATE TRIGGER update_restaurant_menu_items_updated_at BEFORE UPDATE ON public.restaurant_menu_items FOR EACH ROW EXECUTE FUNCTION public.update_restaurant_updated_at();
CREATE TRIGGER update_restaurant_loyalty_points_updated_at BEFORE UPDATE ON public.restaurant_loyalty_points FOR EACH ROW EXECUTE FUNCTION public.update_restaurant_updated_at();
CREATE TRIGGER update_restaurant_settings_updated_at BEFORE UPDATE ON public.restaurant_settings FOR EACH ROW EXECUTE FUNCTION public.update_restaurant_updated_at();