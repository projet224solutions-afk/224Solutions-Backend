
-- Table des paramètres de transfert international (configurables par le PDG)
CREATE TABLE IF NOT EXISTS public.international_transfer_settings (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  setting_key TEXT NOT NULL UNIQUE,
  setting_value NUMERIC NOT NULL,
  description TEXT,
  updated_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.international_transfer_settings ENABLE ROW LEVEL SECURITY;

-- Lecture par tous les utilisateurs authentifiés
CREATE POLICY "Authenticated users can read settings"
  ON public.international_transfer_settings FOR SELECT
  USING (auth.uid() IS NOT NULL);

-- Modification uniquement par les admins/PDG
CREATE POLICY "Only admins can modify settings"
  ON public.international_transfer_settings FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = auth.uid() AND role IN ('admin', 'pdg')
    )
  );

-- Insérer les valeurs par défaut
INSERT INTO public.international_transfer_settings (setting_key, setting_value, description)
VALUES
  ('commission_conversion_percent', 10, 'Commission de conversion en pourcentage'),
  ('frais_transaction_international_percent', 2, 'Frais de transaction internationale en pourcentage'),
  ('delai_verrouillage_taux_seconds', 60, 'Durée de verrouillage du taux en secondes'),
  ('limite_transfert_quotidien', 50000000, 'Limite de transfert quotidien en devise locale')
ON CONFLICT (setting_key) DO NOTHING;

-- Trigger pour updated_at
CREATE TRIGGER update_international_transfer_settings_updated_at
  BEFORE UPDATE ON public.international_transfer_settings
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();
