-- =============================================
-- FIX: LIRE LES FRAIS DEPUIS SYSTEM_SETTINGS
-- Corriger calculate_transfer_fee pour lire depuis system_settings.transfer_fee_percent
-- au lieu d'utiliser un fallback codé en dur
-- =============================================

-- Fonction pour obtenir le taux de frais depuis system_settings
CREATE OR REPLACE FUNCTION public.get_system_transfer_fee_percent()
RETURNS NUMERIC AS $$
DECLARE
  v_fee_percent NUMERIC := 1.5; -- Fallback uniquement si system_settings n'existe pas
BEGIN
  SELECT CAST(setting_value AS NUMERIC)
  INTO v_fee_percent
  FROM public.system_settings
  WHERE setting_key = 'transfer_fee_percent'
  LIMIT 1;

  -- Si la valeur n'existe pas, retourner 1.5% par défaut
  IF v_fee_percent IS NULL OR v_fee_percent < 0 OR v_fee_percent > 100 THEN
    v_fee_percent := 1.5;
  END IF;

  RETURN v_fee_percent;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public;

-- Modifier calculate_transfer_fee pour utiliser system_settings EN PRIORITÉ
CREATE OR REPLACE FUNCTION public.calculate_transfer_fee(
  p_amount NUMERIC,
  p_currency_from VARCHAR,
  p_currency_to VARCHAR,
  p_country_from VARCHAR DEFAULT NULL,
  p_country_to VARCHAR DEFAULT NULL
)
RETURNS TABLE(
  fee_percentage NUMERIC,
  fee_amount NUMERIC,
  amount_after_fee NUMERIC
) AS $$
DECLARE
  v_fee_percentage NUMERIC;
  v_fee_fixed NUMERIC := 0;
  v_system_fee NUMERIC;
BEGIN
  -- 🔥 PRIORITÉ 1: Lire depuis system_settings (modifiable par le PDG)
  v_system_fee := get_system_transfer_fee_percent();

  -- PRIORITÉ 2: Chercher dans transfer_fees (frais spécifiques par corridor)
  SELECT tf.fee_percentage, tf.fee_fixed
  INTO v_fee_percentage, v_fee_fixed
  FROM public.transfer_fees tf
  WHERE tf.is_active = true
    AND (tf.currency_from = p_currency_from OR tf.currency_from IS NULL)
    AND (tf.currency_to = p_currency_to OR tf.currency_to IS NULL)
    AND (tf.country_from = p_country_from OR tf.country_from IS NULL)
    AND (tf.country_to = p_country_to OR tf.country_to IS NULL)
    AND (tf.min_amount IS NULL OR tf.min_amount <= p_amount)
    AND (tf.max_amount IS NULL OR tf.max_amount >= p_amount)
  ORDER BY
    CASE WHEN tf.currency_from IS NOT NULL THEN 1 ELSE 2 END,
    CASE WHEN tf.currency_to IS NOT NULL THEN 1 ELSE 2 END
  LIMIT 1;

  -- Si aucun frais spécifique trouvé, utiliser le taux global depuis system_settings
  IF v_fee_percentage IS NULL THEN
    v_fee_percentage := v_system_fee;
  END IF;

  -- Calculer les frais
  RETURN QUERY SELECT
    v_fee_percentage,
    ROUND((p_amount * v_fee_percentage / 100) + COALESCE(v_fee_fixed, 0), 2) AS fee_amount,
    ROUND(p_amount - ((p_amount * v_fee_percentage / 100) + COALESCE(v_fee_fixed, 0)), 2) AS amount_after_fee;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public;

-- Insérer la valeur par défaut dans system_settings si elle n'existe pas
INSERT INTO public.system_settings (setting_key, setting_value, setting_type, description, created_at, updated_at)
VALUES (
  'transfer_fee_percent',
  '1.5',
  'numeric',
  'Taux de commission global sur les transferts wallet (modifiable par le PDG)',
  NOW(),
  NOW()
)
ON CONFLICT (setting_key) DO NOTHING;

-- Commentaires
COMMENT ON FUNCTION public.get_system_transfer_fee_percent IS 'Obtenir le taux de frais global depuis system_settings.transfer_fee_percent (modifiable par l''interface PDG)';
COMMENT ON FUNCTION public.calculate_transfer_fee IS 'Calculer les frais de transfert en priorité depuis system_settings, puis transfer_fees pour les corridors spécifiques';

-- Log de la migration
DO $$
BEGIN
  RAISE NOTICE '✅ Migration terminée: calculate_transfer_fee lit maintenant depuis system_settings';
  RAISE NOTICE '📊 Les modifications du PDG seront désormais appliquées en temps réel';
END $$;
