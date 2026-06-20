
-- Fonction helper SQL pour lire les frais depuis pdg_settings
CREATE OR REPLACE FUNCTION public.get_pdg_fee_rate(p_setting_key TEXT, p_default_value NUMERIC DEFAULT 0)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_raw JSONB;
  v_rate NUMERIC;
BEGIN
  SELECT setting_value::jsonb INTO v_raw
  FROM pdg_settings
  WHERE setting_key = p_setting_key
  LIMIT 1;

  IF v_raw IS NULL THEN
    RETURN p_default_value;
  END IF;

  -- setting_value peut être { "value": X } ou directement X
  IF v_raw ? 'value' THEN
    v_rate := (v_raw->>'value')::NUMERIC;
  ELSE
    v_rate := v_raw::TEXT::NUMERIC;
  END IF;

  IF v_rate IS NULL OR v_rate < 0 THEN
    RETURN p_default_value;
  END IF;

  RETURN v_rate;
EXCEPTION WHEN OTHERS THEN
  RETURN p_default_value;
END;
$$;

-- Mettre à jour calculate_transfer_fee pour utiliser pdg_settings
CREATE OR REPLACE FUNCTION public.calculate_transfer_fee(p_amount NUMERIC, p_fee_type TEXT DEFAULT 'wallet_fee_percentage')
RETURNS TABLE(fee_amount NUMERIC, net_amount NUMERIC, fee_rate NUMERIC)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rate NUMERIC;
  v_fee NUMERIC;
  v_net NUMERIC;
  v_default NUMERIC;
BEGIN
  -- Defaults selon le type
  CASE p_fee_type
    WHEN 'deposit_fee_percentage' THEN v_default := 2;
    WHEN 'withdrawal_fee_percentage' THEN v_default := 1.5;
    WHEN 'wallet_fee_percentage' THEN v_default := 2.5;
    WHEN 'international_transfer_fee_percentage' THEN v_default := 1;
    WHEN 'commission_achats' THEN v_default := 5;
    WHEN 'commission_services' THEN v_default := 0.5;
    ELSE v_default := 0;
  END CASE;

  v_rate := get_pdg_fee_rate(p_fee_type, v_default);
  v_fee := ROUND(p_amount * (v_rate / 100), 2);
  v_net := ROUND(p_amount - v_fee, 2);

  RETURN QUERY SELECT v_fee, v_net, v_rate;
END;
$$;
