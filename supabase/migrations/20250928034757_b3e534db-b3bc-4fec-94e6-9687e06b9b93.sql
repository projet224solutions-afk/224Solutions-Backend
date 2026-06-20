-- Création des tables pour le module vendeur professionnel

-- Table pour les prospects
CREATE TABLE public.prospects (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  contact_email TEXT,
  contact_phone TEXT,
  company TEXT,
  status TEXT DEFAULT 'prospection' CHECK (status IN ('prospection', 'proposition', 'négociation', 'conclusion', 'perdu')),
  estimated_value NUMERIC DEFAULT 0,
  success_probability INTEGER DEFAULT 0 CHECK (success_probability >= 0 AND success_probability <= 100),
  notes TEXT,
  next_followup_date TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Table pour l'historique des interactions prospects/clients
CREATE TABLE public.interactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  prospect_id UUID REFERENCES public.prospects(id) ON DELETE CASCADE,
  customer_id UUID REFERENCES public.customers(id) ON DELETE CASCADE,
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  type TEXT NOT NULL CHECK (type IN ('appel', 'email', 'meeting', 'chat', 'note')),
  subject TEXT,
  content TEXT,
  scheduled_date TIMESTAMP WITH TIME ZONE,
  completed_date TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Table pour les quotas de crédit clients
CREATE TABLE public.customer_credits (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id UUID NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  credit_limit NUMERIC DEFAULT 0,
  current_balance NUMERIC DEFAULT 0,
  payment_terms INTEGER DEFAULT 30, -- jours
  is_blocked BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  UNIQUE(customer_id, vendor_id)
);

-- Table pour les paiements et échéances
CREATE TABLE public.payment_schedules (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  amount NUMERIC NOT NULL,
  due_date DATE NOT NULL,
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'paid', 'overdue', 'cancelled')),
  payment_method TEXT,
  paid_at TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Table pour les entrepôts
CREATE TABLE public.warehouses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  address TEXT,
  contact_person TEXT,
  contact_phone TEXT,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Mise à jour de la table inventory pour multi-entrepôts
ALTER TABLE public.inventory ADD COLUMN IF NOT EXISTS warehouse_id UUID REFERENCES public.warehouses(id);
ALTER TABLE public.inventory ADD COLUMN IF NOT EXISTS lot_number TEXT;
ALTER TABLE public.inventory ADD COLUMN IF NOT EXISTS expiry_date DATE;
ALTER TABLE public.inventory ADD COLUMN IF NOT EXISTS minimum_stock INTEGER DEFAULT 0;

-- Table pour les codes promotionnels
CREATE TABLE public.promo_codes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  code TEXT NOT NULL UNIQUE,
  description TEXT,
  discount_type TEXT NOT NULL CHECK (discount_type IN ('percentage', 'fixed_amount')),
  discount_value NUMERIC NOT NULL,
  minimum_order_amount NUMERIC DEFAULT 0,
  usage_limit INTEGER,
  used_count INTEGER DEFAULT 0,
  valid_from TIMESTAMP WITH TIME ZONE DEFAULT now(),
  valid_until TIMESTAMP WITH TIME ZONE,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Table pour les employés vendeur
CREATE TABLE public.vendor_employees (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('manager', 'sales', 'stock_manager', 'support', 'preparateur')),
  permissions JSONB DEFAULT '{}',
  is_active BOOLEAN DEFAULT true,
  hired_date DATE DEFAULT CURRENT_DATE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  UNIQUE(vendor_id, user_id)
);

-- Table pour les campagnes marketing
CREATE TABLE public.marketing_campaigns (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  type TEXT NOT NULL CHECK (type IN ('email', 'sms', 'notification', 'social')),
  target_audience JSONB, -- critères de segmentation
  content JSONB, -- contenu de la campagne
  status TEXT DEFAULT 'draft' CHECK (status IN ('draft', 'active', 'paused', 'completed')),
  scheduled_date TIMESTAMP WITH TIME ZONE,
  sent_count INTEGER DEFAULT 0,
  opened_count INTEGER DEFAULT 0,
  clicked_count INTEGER DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Table pour les tickets de support
CREATE TABLE public.support_tickets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  customer_id UUID NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  order_id UUID REFERENCES public.orders(id),
  product_id UUID REFERENCES public.products(id),
  subject TEXT NOT NULL,
  description TEXT,
  priority TEXT DEFAULT 'medium' CHECK (priority IN ('low', 'medium', 'high', 'urgent')),
  status TEXT DEFAULT 'open' CHECK (status IN ('open', 'in_progress', 'waiting_customer', 'resolved', 'closed')),
  assigned_to UUID REFERENCES public.vendor_employees(id),
  resolution TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Triggers pour updated_at
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_prospects_updated_at BEFORE UPDATE ON public.prospects FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_customer_credits_updated_at BEFORE UPDATE ON public.customer_credits FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_support_tickets_updated_at BEFORE UPDATE ON public.support_tickets FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- Ajout d'indexes pour les performances
CREATE INDEX idx_prospects_vendor_id ON public.prospects(vendor_id);
CREATE INDEX idx_prospects_status ON public.prospects(status);
CREATE INDEX idx_interactions_vendor_id ON public.interactions(vendor_id);
CREATE INDEX idx_interactions_type ON public.interactions(type);
CREATE INDEX idx_customer_credits_vendor_id ON public.customer_credits(vendor_id);
CREATE INDEX idx_payment_schedules_due_date ON public.payment_schedules(due_date);
CREATE INDEX idx_payment_schedules_status ON public.payment_schedules(status);
CREATE INDEX idx_inventory_warehouse_id ON public.inventory(warehouse_id);
CREATE INDEX idx_promo_codes_vendor_id ON public.promo_codes(vendor_id);
CREATE INDEX idx_promo_codes_code ON public.promo_codes(code);
CREATE INDEX idx_vendor_employees_vendor_id ON public.vendor_employees(vendor_id);
CREATE INDEX idx_support_tickets_vendor_id ON public.support_tickets(vendor_id);
CREATE INDEX idx_support_tickets_status ON public.support_tickets(status);

-- RLS Policies
ALTER TABLE public.prospects ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.interactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_credits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_schedules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.warehouses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.promo_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vendor_employees ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketing_campaigns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.support_tickets ENABLE ROW LEVEL SECURITY;

-- Policies pour prospects
CREATE POLICY "Vendors can manage their prospects" ON public.prospects
FOR ALL USING (EXISTS (
  SELECT 1 FROM public.vendors v 
  WHERE v.id = prospects.vendor_id AND v.user_id = auth.uid()
));

-- Policies pour interactions
CREATE POLICY "Vendors can manage their interactions" ON public.interactions
FOR ALL USING (EXISTS (
  SELECT 1 FROM public.vendors v 
  WHERE v.id = interactions.vendor_id AND v.user_id = auth.uid()
));

-- Policies pour customer_credits
CREATE POLICY "Vendors can manage their customer credits" ON public.customer_credits
FOR ALL USING (EXISTS (
  SELECT 1 FROM public.vendors v 
  WHERE v.id = customer_credits.vendor_id AND v.user_id = auth.uid()
));

-- Policies pour payment_schedules
CREATE POLICY "Vendors can view their payment schedules" ON public.payment_schedules
FOR SELECT USING (EXISTS (
  SELECT 1 FROM public.orders o
  JOIN public.vendors v ON o.vendor_id = v.id
  WHERE o.id = payment_schedules.order_id AND v.user_id = auth.uid()
));

-- Policies pour warehouses
CREATE POLICY "Vendors can manage their warehouses" ON public.warehouses
FOR ALL USING (EXISTS (
  SELECT 1 FROM public.vendors v 
  WHERE v.id = warehouses.vendor_id AND v.user_id = auth.uid()
));

-- Policies pour promo_codes
CREATE POLICY "Vendors can manage their promo codes" ON public.promo_codes
FOR ALL USING (EXISTS (
  SELECT 1 FROM public.vendors v 
  WHERE v.id = promo_codes.vendor_id AND v.user_id = auth.uid()
));

-- Policies pour vendor_employees
CREATE POLICY "Vendors can manage their employees" ON public.vendor_employees
FOR ALL USING (EXISTS (
  SELECT 1 FROM public.vendors v 
  WHERE v.id = vendor_employees.vendor_id AND v.user_id = auth.uid()
));

-- Policies pour marketing_campaigns
CREATE POLICY "Vendors can manage their campaigns" ON public.marketing_campaigns
FOR ALL USING (EXISTS (
  SELECT 1 FROM public.vendors v 
  WHERE v.id = marketing_campaigns.vendor_id AND v.user_id = auth.uid()
));

-- Policies pour support_tickets
CREATE POLICY "Vendors can manage their tickets" ON public.support_tickets
FOR ALL USING (EXISTS (
  SELECT 1 FROM public.vendors v 
  WHERE v.id = support_tickets.vendor_id AND v.user_id = auth.uid()
));