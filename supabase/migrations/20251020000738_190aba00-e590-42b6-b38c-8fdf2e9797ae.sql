-- Table pour les travailleurs des bureaux syndicaux
CREATE TABLE IF NOT EXISTS public.syndicate_workers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  bureau_id UUID REFERENCES public.bureaus(id) ON DELETE CASCADE,
  nom TEXT NOT NULL,
  email TEXT NOT NULL,
  telephone TEXT,
  access_token TEXT UNIQUE NOT NULL,
  interface_url TEXT NOT NULL,
  access_level TEXT NOT NULL DEFAULT 'limited',
  permissions JSONB DEFAULT '{"view_members": false, "add_members": false, "edit_members": false, "view_vehicles": true, "add_vehicles": false, "view_reports": false}'::jsonb,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Table pour les fonctionnalités des bureaux
CREATE TABLE IF NOT EXISTS public.bureau_features (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  feature_name TEXT NOT NULL,
  feature_code TEXT UNIQUE NOT NULL,
  description TEXT,
  version TEXT NOT NULL DEFAULT '1.0.0',
  is_active BOOLEAN DEFAULT true,
  config JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Table de liaison bureaux <-> fonctionnalités
CREATE TABLE IF NOT EXISTS public.bureau_feature_assignments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  bureau_id UUID REFERENCES public.bureaus(id) ON DELETE CASCADE,
  feature_id UUID REFERENCES public.bureau_features(id) ON DELETE CASCADE,
  enabled BOOLEAN DEFAULT true,
  assigned_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  UNIQUE(bureau_id, feature_id)
);

-- Table pour les alertes
CREATE TABLE IF NOT EXISTS public.syndicate_alerts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  bureau_id UUID REFERENCES public.bureaus(id) ON DELETE CASCADE,
  alert_type TEXT NOT NULL,
  severity TEXT NOT NULL DEFAULT 'info',
  title TEXT NOT NULL,
  message TEXT NOT NULL,
  is_read BOOLEAN DEFAULT false,
  is_critical BOOLEAN DEFAULT false,
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  resolved_at TIMESTAMP WITH TIME ZONE
);

-- Table pour les motos enregistrées
CREATE TABLE IF NOT EXISTS public.registered_motos (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  bureau_id UUID REFERENCES public.bureaus(id) ON DELETE CASCADE,
  worker_id UUID REFERENCES public.syndicate_workers(id) ON DELETE SET NULL,
  serial_number TEXT NOT NULL,
  brand TEXT,
  model TEXT,
  year INTEGER,
  color TEXT,
  registration_date TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  status TEXT DEFAULT 'active',
  metadata JSONB DEFAULT '{}'::jsonb,
  UNIQUE(serial_number)
);

-- Ajouter le champ access_token à la table bureaus
ALTER TABLE public.bureaus 
ADD COLUMN IF NOT EXISTS access_token TEXT UNIQUE,
ADD COLUMN IF NOT EXISTS interface_url TEXT;

-- Générer des tokens pour les bureaux existants
UPDATE public.bureaus 
SET access_token = gen_random_uuid()::text 
WHERE access_token IS NULL;

-- Index pour améliorer les performances
CREATE INDEX IF NOT EXISTS idx_workers_bureau ON public.syndicate_workers(bureau_id);
CREATE INDEX IF NOT EXISTS idx_workers_email ON public.syndicate_workers(email);
CREATE INDEX IF NOT EXISTS idx_alerts_bureau ON public.syndicate_alerts(bureau_id);
CREATE INDEX IF NOT EXISTS idx_alerts_critical ON public.syndicate_alerts(is_critical) WHERE is_critical = true;
CREATE INDEX IF NOT EXISTS idx_motos_serial ON public.registered_motos(serial_number);
CREATE INDEX IF NOT EXISTS idx_motos_bureau ON public.registered_motos(bureau_id);

-- Trigger pour updated_at
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_syndicate_workers_updated_at
  BEFORE UPDATE ON public.syndicate_workers
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_bureau_features_updated_at
  BEFORE UPDATE ON public.bureau_features
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

-- RLS Policies pour syndicate_workers
ALTER TABLE public.syndicate_workers ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Workers can view their own data"
ON public.syndicate_workers FOR SELECT
TO authenticated
USING (auth.uid()::text = email OR EXISTS (
  SELECT 1 FROM public.bureaus 
  WHERE bureaus.id = syndicate_workers.bureau_id 
  AND bureaus.president_email = auth.jwt()->>'email'
));

CREATE POLICY "Bureau presidents can manage their workers"
ON public.syndicate_workers FOR ALL
TO authenticated
USING (EXISTS (
  SELECT 1 FROM public.bureaus 
  WHERE bureaus.id = syndicate_workers.bureau_id 
  AND bureaus.president_email = auth.jwt()->>'email'
));

CREATE POLICY "Admins can manage all workers"
ON public.syndicate_workers FOR ALL
TO authenticated
USING (EXISTS (
  SELECT 1 FROM public.profiles
  WHERE profiles.id = auth.uid()
  AND profiles.role = 'admin'
));

-- RLS Policies pour bureau_features
ALTER TABLE public.bureau_features ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Everyone can view active features"
ON public.bureau_features FOR SELECT
TO authenticated
USING (is_active = true);

CREATE POLICY "Admins can manage features"
ON public.bureau_features FOR ALL
TO authenticated
USING (EXISTS (
  SELECT 1 FROM public.profiles
  WHERE profiles.id = auth.uid()
  AND profiles.role = 'admin'
));

-- RLS Policies pour syndicate_alerts
ALTER TABLE public.syndicate_alerts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Bureau members can view their alerts"
ON public.syndicate_alerts FOR SELECT
TO authenticated
USING (
  bureau_id IN (
    SELECT id FROM public.bureaus 
    WHERE president_email = auth.jwt()->>'email'
  ) OR
  bureau_id IN (
    SELECT bureau_id FROM public.syndicate_workers 
    WHERE email = auth.jwt()->>'email'
  )
);

CREATE POLICY "Admins can view all alerts"
ON public.syndicate_alerts FOR SELECT
TO authenticated
USING (EXISTS (
  SELECT 1 FROM public.profiles
  WHERE profiles.id = auth.uid()
  AND profiles.role = 'admin'
));

CREATE POLICY "Admins and bureau presidents can create alerts"
ON public.syndicate_alerts FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'
  ) OR
  bureau_id IN (
    SELECT id FROM public.bureaus 
    WHERE president_email = auth.jwt()->>'email'
  )
);

-- RLS Policies pour registered_motos
ALTER TABLE public.registered_motos ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Bureau members can view their motos"
ON public.registered_motos FOR SELECT
TO authenticated
USING (
  bureau_id IN (
    SELECT id FROM public.bureaus 
    WHERE president_email = auth.jwt()->>'email'
  ) OR
  bureau_id IN (
    SELECT bureau_id FROM public.syndicate_workers 
    WHERE email = auth.jwt()->>'email'
  )
);

CREATE POLICY "Bureau presidents and authorized workers can add motos"
ON public.registered_motos FOR INSERT
TO authenticated
WITH CHECK (
  bureau_id IN (
    SELECT id FROM public.bureaus 
    WHERE president_email = auth.jwt()->>'email'
  ) OR
  (
    bureau_id IN (
      SELECT bureau_id FROM public.syndicate_workers 
      WHERE email = auth.jwt()->>'email'
      AND (permissions->>'add_vehicles')::boolean = true
    )
  )
);

CREATE POLICY "Admins can manage all motos"
ON public.registered_motos FOR ALL
TO authenticated
USING (EXISTS (
  SELECT 1 FROM public.profiles
  WHERE profiles.id = auth.uid()
  AND profiles.role = 'admin'
));

-- Insérer quelques fonctionnalités de base
INSERT INTO public.bureau_features (feature_name, feature_code, description, version) VALUES
  ('Gestion des membres', 'MEMBER_MANAGEMENT', 'Ajouter, modifier et gérer les membres du bureau', '1.0.0'),
  ('Enregistrement véhicules', 'VEHICLE_REGISTRATION', 'Enregistrer et suivre les motos des membres', '1.0.0'),
  ('Alertes et notifications', 'ALERTS_NOTIFICATIONS', 'Système d''alertes et notifications en temps réel', '1.0.0'),
  ('Rapports statistiques', 'STATISTICS_REPORTS', 'Générer des rapports et statistiques du bureau', '1.0.0'),
  ('Communication technique', 'TECH_SUPPORT', 'Communication avec l''équipe technique', '1.0.0')
ON CONFLICT (feature_code) DO NOTHING;