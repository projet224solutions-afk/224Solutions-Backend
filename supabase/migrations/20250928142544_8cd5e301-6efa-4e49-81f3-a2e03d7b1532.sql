-- Créer une table pour les paramètres du système POS
CREATE TABLE public.pos_settings (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  vendor_id UUID NOT NULL,
  tax_rate DECIMAL(5,4) NOT NULL DEFAULT 0.18, -- 18% par défaut
  currency VARCHAR(10) NOT NULL DEFAULT 'FCFA',
  company_name VARCHAR(255),
  receipt_footer TEXT,
  auto_print_receipt BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(vendor_id)
);

-- Activer RLS
ALTER TABLE public.pos_settings ENABLE ROW LEVEL SECURITY;

-- Politique pour que les vendeurs accèdent à leurs propres paramètres
CREATE POLICY "Vendors can view their own POS settings" 
ON public.pos_settings 
FOR SELECT 
USING (auth.uid() = vendor_id);

CREATE POLICY "Vendors can insert their own POS settings" 
ON public.pos_settings 
FOR INSERT 
WITH CHECK (auth.uid() = vendor_id);

CREATE POLICY "Vendors can update their own POS settings" 
ON public.pos_settings 
FOR UPDATE 
USING (auth.uid() = vendor_id);

-- Fonction pour créer automatiquement les paramètres par défaut
CREATE OR REPLACE FUNCTION public.create_default_pos_settings()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.pos_settings (vendor_id, company_name)
  VALUES (NEW.id, COALESCE(NEW.company_name, 'Mon Commerce'))
  ON CONFLICT (vendor_id) DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger pour créer automatiquement les paramètres quand un profil est créé avec le rôle vendeur
CREATE TRIGGER create_pos_settings_on_vendor_profile
  AFTER INSERT ON public.profiles
  FOR EACH ROW
  WHEN (NEW.role = 'vendeur')
  EXECUTE FUNCTION public.create_default_pos_settings();

-- Trigger pour mettre à jour updated_at
CREATE TRIGGER update_pos_settings_updated_at
  BEFORE UPDATE ON public.pos_settings
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();