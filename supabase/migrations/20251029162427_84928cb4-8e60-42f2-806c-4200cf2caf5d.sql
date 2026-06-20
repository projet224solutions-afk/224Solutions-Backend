-- Créer la table des alertes de sécurité pour les motos
CREATE TABLE IF NOT EXISTS public.moto_security_alerts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plate_number TEXT NOT NULL,
  serial_number TEXT NOT NULL,
  brand TEXT NOT NULL,
  model TEXT NOT NULL,
  owner_name TEXT NOT NULL,
  owner_phone TEXT NOT NULL,
  reported_bureau_id UUID NOT NULL,
  reported_bureau_name TEXT NOT NULL,
  reported_location TEXT NOT NULL,
  detected_bureau_id UUID NOT NULL,
  description TEXT,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'resolved', 'investigating')),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Index pour les recherches fréquentes
CREATE INDEX idx_moto_security_alerts_detected_bureau ON public.moto_security_alerts(detected_bureau_id);
CREATE INDEX idx_moto_security_alerts_status ON public.moto_security_alerts(status);
CREATE INDEX idx_moto_security_alerts_plate ON public.moto_security_alerts(plate_number);
CREATE INDEX idx_moto_security_alerts_serial ON public.moto_security_alerts(serial_number);

-- Activer RLS
ALTER TABLE public.moto_security_alerts ENABLE ROW LEVEL SECURITY;

-- Politique: Les utilisateurs authentifiés peuvent voir toutes les alertes
CREATE POLICY "Authenticated users can view all security alerts"
ON public.moto_security_alerts
FOR SELECT
TO authenticated
USING (true);

-- Politique: Les utilisateurs authentifiés peuvent créer des alertes
CREATE POLICY "Authenticated users can create security alerts"
ON public.moto_security_alerts
FOR INSERT
TO authenticated
WITH CHECK (true);

-- Politique: Les utilisateurs authentifiés peuvent mettre à jour les alertes de leur bureau
CREATE POLICY "Authenticated users can update security alerts"
ON public.moto_security_alerts
FOR UPDATE
TO authenticated
USING (true)
WITH CHECK (true);

-- Trigger pour mettre à jour updated_at
CREATE OR REPLACE FUNCTION public.update_moto_security_alerts_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_moto_security_alerts_updated_at
BEFORE UPDATE ON public.moto_security_alerts
FOR EACH ROW
EXECUTE FUNCTION public.update_moto_security_alerts_updated_at();