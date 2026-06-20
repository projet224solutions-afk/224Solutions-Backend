-- Table pour les certifications de sécurité
CREATE TABLE IF NOT EXISTS public.security_certifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR(255) NOT NULL,
  certification_type VARCHAR(100) NOT NULL,
  status VARCHAR(50) NOT NULL DEFAULT 'planned' CHECK (status IN ('certified', 'in_progress', 'planned', 'expired')),
  progress INTEGER NOT NULL DEFAULT 0 CHECK (progress >= 0 AND progress <= 100),
  valid_from TIMESTAMP WITH TIME ZONE,
  valid_until TIMESTAMP WITH TIME ZONE,
  description TEXT,
  issuing_authority VARCHAR(255),
  certificate_url TEXT,
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Index pour recherche rapide
CREATE INDEX IF NOT EXISTS idx_security_certifications_status ON public.security_certifications(status);
CREATE INDEX IF NOT EXISTS idx_security_certifications_type ON public.security_certifications(certification_type);

-- Enable RLS
ALTER TABLE public.security_certifications ENABLE ROW LEVEL SECURITY;

-- Politique: Lecture pour tous les utilisateurs authentifiés
CREATE POLICY "Authenticated users can view certifications"
  ON public.security_certifications
  FOR SELECT
  TO authenticated
  USING (true);

-- Politique: Seuls les admins peuvent modifier
CREATE POLICY "Only admins can manage certifications"
  ON public.security_certifications
  FOR ALL
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM profiles
      WHERE profiles.id = auth.uid()
      AND profiles.role = 'admin'
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM profiles
      WHERE profiles.id = auth.uid()
      AND profiles.role = 'admin'
    )
  );

-- Trigger pour mettre à jour updated_at
CREATE TRIGGER update_security_certifications_updated_at
  BEFORE UPDATE ON public.security_certifications
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

-- Données initiales
INSERT INTO public.security_certifications (name, certification_type, status, progress, description, issuing_authority) VALUES
  ('ISO 27001', 'iso27001', 'in_progress', 65, 'Système de management de la sécurité de l''information', 'International Organization for Standardization'),
  ('PCI-DSS', 'pci_dss', 'in_progress', 45, 'Norme de sécurité des données de carte de paiement', 'PCI Security Standards Council'),
  ('SOC 2 Type II', 'soc2', 'planned', 20, 'Contrôles de sécurité organisationnels', 'American Institute of CPAs')
ON CONFLICT DO NOTHING;

-- Certifications complètes avec dates de validité
INSERT INTO public.security_certifications (name, certification_type, status, progress, description, issuing_authority, valid_from, valid_until) VALUES
  ('GDPR Compliance', 'gdpr', 'certified', 100, 'Règlement général sur la protection des données', 'European Union', NOW() - INTERVAL '6 months', NOW() + INTERVAL '18 months'),
  ('ISO 9001', 'iso9001', 'certified', 100, 'Système de management de la qualité', 'International Organization for Standardization', NOW() - INTERVAL '1 year', NOW() + INTERVAL '2 years')
ON CONFLICT DO NOTHING;