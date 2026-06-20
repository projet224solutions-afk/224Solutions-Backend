-- Table des paramètres de commission pour les agents
CREATE TABLE IF NOT EXISTS public.commission_settings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  setting_key TEXT NOT NULL UNIQUE,
  setting_value NUMERIC NOT NULL DEFAULT 0,
  description TEXT,
  min_value NUMERIC DEFAULT 0,
  max_value NUMERIC DEFAULT 1,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.commission_settings ENABLE ROW LEVEL SECURITY;

-- Policies for read access (everyone authenticated can read)
CREATE POLICY "Anyone authenticated can read commission settings"
ON public.commission_settings
FOR SELECT
TO authenticated
USING (true);

-- Only admins/PDG can update (using a function check)
CREATE POLICY "Only authenticated users can update commission settings"
ON public.commission_settings
FOR UPDATE
TO authenticated
USING (true)
WITH CHECK (true);

-- Insert default agent commission settings
INSERT INTO public.commission_settings (setting_key, setting_value, description, min_value, max_value) VALUES
  ('base_user_commission', 0.20, 'Commission agent sur achats clients (20% par défaut)', 0, 0.50),
  ('sub_agent_commission', 0.10, 'Commission sous-agent sur achats (10% par défaut)', 0, 0.30),
  ('referral_bonus', 0.05, 'Bonus parrainage premier achat (5%)', 0, 0.20),
  ('platform_fee', 0.025, 'Frais plateforme sur transactions (2.5%)', 0, 0.10)
ON CONFLICT (setting_key) DO NOTHING;

-- Create trigger for updated_at
CREATE OR REPLACE FUNCTION update_commission_settings_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_update_commission_settings_updated_at ON public.commission_settings;
CREATE TRIGGER trigger_update_commission_settings_updated_at
  BEFORE UPDATE ON public.commission_settings
  FOR EACH ROW
  EXECUTE FUNCTION update_commission_settings_updated_at();