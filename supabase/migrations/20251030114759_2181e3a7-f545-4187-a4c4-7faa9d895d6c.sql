-- Créer une table pour le wallet PDG et les revenus de la plateforme
CREATE TABLE IF NOT EXISTS platform_revenue (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  revenue_type TEXT NOT NULL, -- 'transfer_fee', 'order_commission', 'vendor_subscription', 'driver_subscription', 'withdrawal_fee'
  amount DECIMAL(15,2) NOT NULL,
  source_transaction_id UUID, -- ID de la transaction source
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Index pour optimiser les requêtes
CREATE INDEX IF NOT EXISTS idx_platform_revenue_type ON platform_revenue(revenue_type);
CREATE INDEX IF NOT EXISTS idx_platform_revenue_created ON platform_revenue(created_at DESC);

-- Ajouter la configuration du wallet PDG dans system_settings
INSERT INTO system_settings (setting_key, setting_value, description)
VALUES 
  ('pdg_wallet_id', '00000000-0000-0000-0000-000000000001', 'ID du wallet PDG pour les revenus de la plateforme'),
  ('order_commission_percent', '5.0', 'Commission sur les achats clients (%)'),
  ('vendor_subscription_amount', '50000', 'Montant abonnement vendeur mensuel (GNF)'),
  ('driver_subscription_amount', '30000', 'Montant abonnement livreur/taxi mensuel (GNF)'),
  ('withdrawal_fee_percent', '2.0', 'Frais de retrait de l''application (%)')
ON CONFLICT (setting_key) DO NOTHING;

-- Fonction pour enregistrer un revenu de la plateforme
CREATE OR REPLACE FUNCTION record_platform_revenue(
  p_revenue_type TEXT,
  p_amount DECIMAL,
  p_source_transaction_id UUID DEFAULT NULL,
  p_metadata JSONB DEFAULT '{}'::jsonb
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_revenue_id UUID;
  v_pdg_wallet_id UUID;
BEGIN
  -- Récupérer l'ID du wallet PDG
  SELECT setting_value::UUID INTO v_pdg_wallet_id
  FROM system_settings
  WHERE setting_key = 'pdg_wallet_id';

  -- Enregistrer le revenu
  INSERT INTO platform_revenue (revenue_type, amount, source_transaction_id, metadata)
  VALUES (p_revenue_type, p_amount, p_source_transaction_id, p_metadata)
  RETURNING id INTO v_revenue_id;

  -- Créditer le wallet PDG si existe
  IF EXISTS (SELECT 1 FROM wallets WHERE id = v_pdg_wallet_id) THEN
    UPDATE wallets 
    SET balance = balance + p_amount,
        updated_at = now()
    WHERE id = v_pdg_wallet_id;
  END IF;

  RETURN v_revenue_id;
END;
$$;

-- Fonction pour obtenir les statistiques des revenus
CREATE OR REPLACE FUNCTION get_platform_revenue_stats(
  p_start_date TIMESTAMP WITH TIME ZONE DEFAULT NULL,
  p_end_date TIMESTAMP WITH TIME ZONE DEFAULT NULL
)
RETURNS TABLE(
  revenue_type TEXT,
  total_amount DECIMAL,
  transaction_count BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT 
    pr.revenue_type,
    COALESCE(SUM(pr.amount), 0) as total_amount,
    COUNT(*)::BIGINT as transaction_count
  FROM platform_revenue pr
  WHERE 
    (p_start_date IS NULL OR pr.created_at >= p_start_date)
    AND (p_end_date IS NULL OR pr.created_at <= p_end_date)
  GROUP BY pr.revenue_type
  ORDER BY total_amount DESC;
END;
$$;

-- Enable RLS
ALTER TABLE platform_revenue ENABLE ROW LEVEL SECURITY;

-- Policy: Seuls les admins peuvent lire les revenus
CREATE POLICY "Admins can view platform revenue"
ON platform_revenue
FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'
  )
);

-- Policy: Système peut insérer des revenus
CREATE POLICY "System can insert platform revenue"
ON platform_revenue
FOR INSERT
WITH CHECK (true);

COMMENT ON TABLE platform_revenue IS 'Enregistrement de tous les revenus de la plateforme';
COMMENT ON FUNCTION record_platform_revenue IS 'Enregistre un revenu et crédite le wallet PDG';
COMMENT ON FUNCTION get_platform_revenue_stats IS 'Statistiques des revenus par type';