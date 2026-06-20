-- =============================================
-- FRAIS ADAPTATIFS PAR CORRIDOR DE PAIEMENT - PHASE 3
-- Utiliser la table transfer_fees pour appliquer des frais spécifiques par pays
-- =============================================

-- 1. Insérer les frais par corridor de paiement
INSERT INTO public.transfer_fees (
  country_from, 
  country_to, 
  currency_from, 
  currency_to, 
  min_amount, 
  max_amount,
  fee_percentage, 
  fee_fixed,
  is_active,
  created_at
) VALUES
  -- Transferts locaux (Guinée → Guinée)
  ('GN', 'GN', 'GNF', 'GNF', 0, NULL, 0.5, 0, true, NOW()),
  
  -- Transferts Guinée → Europe
  ('GN', 'FR', 'GNF', 'EUR', 0, NULL, 2.5, 0, true, NOW()),
  ('GN', 'DE', 'GNF', 'EUR', 0, NULL, 2.5, 0, true, NOW()),
  ('GN', 'IT', 'GNF', 'EUR', 0, NULL, 2.5, 0, true, NOW()),
  ('GN', 'ES', 'GNF', 'EUR', 0, NULL, 2.5, 0, true, NOW()),
  ('GN', 'PT', 'GNF', 'EUR', 0, NULL, 2.5, 0, true, NOW()),
  ('GN', 'BE', 'GNF', 'EUR', 0, NULL, 2.5, 0, true, NOW()),
  ('GN', 'NL', 'GNF', 'EUR', 0, NULL, 2.5, 0, true, NOW()),
  ('GN', 'GB', 'GNF', 'GBP', 0, NULL, 2.8, 0, true, NOW()),
  
  -- Transferts Guinée → Afrique de l'Ouest (CEDEAO)
  ('GN', 'CI', 'GNF', 'XOF', 0, NULL, 1.0, 0, true, NOW()),
  ('GN', 'SN', 'GNF', 'XOF', 0, NULL, 1.0, 0, true, NOW()),
  ('GN', 'ML', 'GNF', 'XOF', 0, NULL, 1.0, 0, true, NOW()),
  ('GN', 'BF', 'GNF', 'XOF', 0, NULL, 1.0, 0, true, NOW()),
  ('GN', 'BJ', 'GNF', 'XOF', 0, NULL, 1.0, 0, true, NOW()),
  ('GN', 'TG', 'GNF', 'XOF', 0, NULL, 1.0, 0, true, NOW()),
  ('GN', 'NE', 'GNF', 'XOF', 0, NULL, 1.0, 0, true, NOW()),
  ('GN', 'NG', 'GNF', 'NGN', 0, NULL, 1.2, 0, true, NOW()),
  ('GN', 'GH', 'GNF', 'GHS', 0, NULL, 1.2, 0, true, NOW()),
  
  -- Transferts Guinée → Afrique Centrale
  ('GN', 'CM', 'GNF', 'XAF', 0, NULL, 1.5, 0, true, NOW()),
  ('GN', 'GA', 'GNF', 'XAF', 0, NULL, 1.5, 0, true, NOW()),
  ('GN', 'CG', 'GNF', 'XAF', 0, NULL, 1.5, 0, true, NOW()),
  
  -- Transferts Guinée → Amérique
  ('GN', 'US', 'GNF', 'USD', 0, NULL, 3.0, 0, true, NOW()),
  ('GN', 'CA', 'GNF', 'CAD', 0, NULL, 3.0, 0, true, NOW()),
  ('GN', 'BR', 'GNF', 'BRL', 0, NULL, 2.8, 0, true, NOW()),
  
  -- Transferts Guinée → Asie
  ('GN', 'CN', 'GNF', 'CNY', 0, NULL, 3.5, 0, true, NOW()),
  ('GN', 'JP', 'GNF', 'JPY', 0, NULL, 3.5, 0, true, NOW()),
  ('GN', 'IN', 'GNF', 'INR', 0, NULL, 2.5, 0, true, NOW()),
  ('GN', 'SA', 'GNF', 'SAR', 0, NULL, 2.8, 0, true, NOW()),
  ('GN', 'AE', 'GNF', 'AED', 0, NULL, 2.8, 0, true, NOW()),
  
  -- Transferts Guinée → Afrique du Nord
  ('GN', 'MA', 'GNF', 'MAD', 0, NULL, 1.8, 0, true, NOW()),
  ('GN', 'DZ', 'GNF', 'DZD', 0, NULL, 1.8, 0, true, NOW()),
  ('GN', 'TN', 'GNF', 'TND', 0, NULL, 1.8, 0, true, NOW()),
  ('GN', 'EG', 'GNF', 'EGP', 0, NULL, 1.8, 0, true, NOW()),
  
  -- Transferts Europe → Guinée
  ('FR', 'GN', 'EUR', 'GNF', 0, NULL, 2.5, 0, true, NOW()),
  ('DE', 'GN', 'EUR', 'GNF', 0, NULL, 2.5, 0, true, NOW()),
  ('IT', 'GN', 'EUR', 'GNF', 0, NULL, 2.5, 0, true, NOW()),
  ('ES', 'GN', 'EUR', 'GNF', 0, NULL, 2.5, 0, true, NOW()),
  ('GB', 'GN', 'GBP', 'GNF', 0, NULL, 2.8, 0, true, NOW()),
  
  -- Transferts Afrique de l'Ouest → Guinée
  ('CI', 'GN', 'XOF', 'GNF', 0, NULL, 1.0, 0, true, NOW()),
  ('SN', 'GN', 'XOF', 'GNF', 0, NULL, 1.0, 0, true, NOW()),
  ('ML', 'GN', 'XOF', 'GNF', 0, NULL, 1.0, 0, true, NOW()),
  
  -- Transferts entre pays zone franc
  ('CI', 'SN', 'XOF', 'XOF', 0, NULL, 0.3, 0, true, NOW()),
  ('CI', 'ML', 'XOF', 'XOF', 0, NULL, 0.3, 0, true, NOW()),
  ('SN', 'ML', 'XOF', 'XOF', 0, NULL, 0.3, 0, true, NOW()),
  ('BF', 'BJ', 'XOF', 'XOF', 0, NULL, 0.3, 0, true, NOW())
ON CONFLICT DO NOTHING;

-- 2. Fonction pour obtenir les frais de transfert par corridor
CREATE OR REPLACE FUNCTION get_transfer_fee_by_corridor(
  p_country_from VARCHAR(3),
  p_country_to VARCHAR(3),
  p_currency_from VARCHAR(3),
  p_currency_to VARCHAR(3),
  p_amount NUMERIC
)
RETURNS TABLE(
  fee_percentage NUMERIC,
  fee_fixed NUMERIC,
  fee_amount NUMERIC,
  total_fee NUMERIC
) AS $$
DECLARE
  v_fee_percentage NUMERIC := 1.5; -- Frais par défaut
  v_fee_fixed NUMERIC := 0;
  v_fee_amount NUMERIC;
  v_total_fee NUMERIC;
BEGIN
  -- Chercher frais spécifiques
  SELECT 
    tf.fee_percentage,
    tf.fee_fixed
  INTO v_fee_percentage, v_fee_fixed
  FROM transfer_fees tf
  WHERE tf.country_from = p_country_from
    AND tf.country_to = p_country_to
    AND tf.currency_from = p_currency_from
    AND tf.currency_to = p_currency_to
    AND tf.is_active = true
    AND (tf.min_amount IS NULL OR p_amount >= tf.min_amount)
    AND (tf.max_amount IS NULL OR p_amount <= tf.max_amount)
  ORDER BY tf.created_at DESC
  LIMIT 1;
  
  -- Si pas de frais spécifique, vérifier frais par pays uniquement
  IF v_fee_percentage IS NULL THEN
    SELECT 
      tf.fee_percentage,
      tf.fee_fixed
    INTO v_fee_percentage, v_fee_fixed
    FROM transfer_fees tf
    WHERE tf.country_from = p_country_from
      AND tf.country_to = p_country_to
      AND tf.is_active = true
      AND (tf.min_amount IS NULL OR p_amount >= tf.min_amount)
      AND (tf.max_amount IS NULL OR p_amount <= tf.max_amount)
    ORDER BY tf.created_at DESC
    LIMIT 1;
  END IF;
  
  -- Calculer montant des frais
  v_fee_amount := p_amount * (v_fee_percentage / 100);
  v_total_fee := v_fee_amount + COALESCE(v_fee_fixed, 0);
  
  RETURN QUERY SELECT 
    v_fee_percentage,
    COALESCE(v_fee_fixed, 0::NUMERIC),
    v_fee_amount,
    v_total_fee;
END;
$$ LANGUAGE plpgsql STABLE;

-- 3. Fonction de calcul de frais améliorée (remplace calculate_transfer_fee)
CREATE OR REPLACE FUNCTION calculate_transfer_fee_enhanced(
  p_amount NUMERIC,
  p_currency_from VARCHAR(3),
  p_currency_to VARCHAR(3),
  p_country_from VARCHAR(3) DEFAULT 'GN',
  p_country_to VARCHAR(3) DEFAULT 'GN'
)
RETURNS TABLE(
  fee_percentage NUMERIC,
  fee_amount NUMERIC,
  amount_after_fee NUMERIC,
  corridor VARCHAR(100)
) AS $$
DECLARE
  v_fee_result RECORD;
  v_corridor VARCHAR(100);
BEGIN
  -- Obtenir frais par corridor
  SELECT * INTO v_fee_result 
  FROM get_transfer_fee_by_corridor(
    p_country_from,
    p_country_to,
    p_currency_from,
    p_currency_to,
    p_amount
  );
  
  v_corridor := p_country_from || ' → ' || p_country_to || ' (' || p_currency_from || '→' || p_currency_to || ')';
  
  RETURN QUERY SELECT 
    v_fee_result.fee_percentage,
    v_fee_result.total_fee,
    p_amount - v_fee_result.total_fee,
    v_corridor;
END;
$$ LANGUAGE plpgsql STABLE;

-- 4. Vue pour analytics des corridors de paiement
CREATE OR REPLACE VIEW v_payment_corridor_analytics AS
SELECT 
  wt.sender_country || ' → ' || wt.receiver_country AS corridor,
  wt.sender_country,
  wt.receiver_country,
  wt.currency_sent,
  wt.currency_received,
  COUNT(*) AS transfer_count,
  SUM(wt.amount_sent) AS total_sent,
  SUM(wt.amount_received) AS total_received,
  AVG(wt.fee_percentage) AS avg_fee_percentage,
  SUM(wt.fee_amount) AS total_fees_collected,
  SUM((wt.rate_used - wt.rate_displayed) * wt.amount_after_fee) AS total_margin_revenue,
  MIN(wt.created_at) AS first_transfer,
  MAX(wt.created_at) AS last_transfer
FROM wallet_transfers wt
WHERE wt.status = 'completed'
  AND wt.sender_country IS NOT NULL
  AND wt.receiver_country IS NOT NULL
GROUP BY 
  wt.sender_country,
  wt.receiver_country,
  wt.currency_sent,
  wt.currency_received;

-- 5. Commentaires
COMMENT ON FUNCTION get_transfer_fee_by_corridor IS 'Obtenir frais de transfert spécifiques à un corridor de paiement (pays + devises)';
COMMENT ON FUNCTION calculate_transfer_fee_enhanced IS 'Calculer frais de transfert avec support des corridors internationaux';
COMMENT ON VIEW v_payment_corridor_analytics IS 'Analytics des corridors de paiement internationaux (volumes, frais, marges)';

-- 6. Permissions RLS
ALTER TABLE public.transfer_fees ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Transfer fees readable by all" ON public.transfer_fees;
CREATE POLICY "Transfer fees readable by all"
ON public.transfer_fees FOR SELECT
USING (is_active = true);

DROP POLICY IF EXISTS "Transfer fees manageable by admins" ON public.transfer_fees;
CREATE POLICY "Transfer fees manageable by admins"
ON public.transfer_fees FOR ALL
USING (
  EXISTS (
    SELECT 1 FROM profiles 
    WHERE profiles.id = auth.uid() 
    AND profiles.role = 'admin'
  )
);
