-- =====================================================
-- CORRECTION DES COMMISSIONS MARKETPLACE POUR LIRE DEPUIS SYSTEM_SETTINGS
-- 224SOLUTIONS - 31 Janvier 2026
-- =====================================================
-- Problème identifié:
-- 1. Le PDG modifie pdg_settings.purchase_commission_percentage
-- 2. Le trigger synchronise vers system_settings.purchase_fee_percent
-- 3. MAIS ProductPaymentModal lit depuis commission_config (jamais synchronisé!)
-- Solution: Créer des fonctions SQL qui lisent depuis system_settings
-- =====================================================

-- 1. NOUVELLE FONCTION: Obtenir le taux de commission sur les ACHATS (marketplace)
CREATE OR REPLACE FUNCTION public.get_purchase_commission_percent()
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  v_fee_percent NUMERIC := 10; -- Valeur par défaut 10%
BEGIN
  -- Priorité 1: Lire depuis system_settings (synchronisé depuis pdg_settings)
  SELECT CAST(setting_value AS NUMERIC)
  INTO v_fee_percent
  FROM public.system_settings
  WHERE setting_key = 'purchase_fee_percent'
  LIMIT 1;

  -- Validation: entre 0 et 30
  IF v_fee_percent IS NULL OR v_fee_percent < 0 OR v_fee_percent > 30 THEN
    v_fee_percent := 10; -- Fallback 10%
  END IF;

  RETURN v_fee_percent;
END;
$$;

-- 2. NOUVELLE FONCTION: Obtenir le taux de commission sur les SERVICES
CREATE OR REPLACE FUNCTION public.get_service_commission_percent()
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  v_fee_percent NUMERIC := 0.5; -- Valeur par défaut 0.5%
BEGIN
  -- Lire depuis system_settings (synchronisé depuis pdg_settings.service_commissions)
  SELECT CAST(setting_value AS NUMERIC)
  INTO v_fee_percent
  FROM public.system_settings
  WHERE setting_key = 'service_fee_percent'
  LIMIT 1;

  -- Validation: entre 0 et 20
  IF v_fee_percent IS NULL OR v_fee_percent < 0 OR v_fee_percent > 20 THEN
    v_fee_percent := 0.5;
  END IF;

  RETURN v_fee_percent;
END;
$$;

-- 3. Fonction RPC pour obtenir toutes les commissions PDG (pour le frontend)
CREATE OR REPLACE FUNCTION public.get_pdg_commission_config()
RETURNS TABLE(
  transfer_fee_percent NUMERIC,
  purchase_fee_percent NUMERIC,
  service_fee_percent NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
  RETURN QUERY SELECT
    public.get_system_transfer_fee_percent() AS transfer_fee_percent,
    public.get_purchase_commission_percent() AS purchase_fee_percent,
    public.get_service_commission_percent() AS service_fee_percent;
END;
$$;

-- 4. Fonction pour calculer la commission d'achat
CREATE OR REPLACE FUNCTION public.calculate_purchase_commission(
  p_amount NUMERIC
)
RETURNS TABLE(
  commission_percent NUMERIC,
  commission_amount NUMERIC,
  amount_after_commission NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  v_percent NUMERIC;
BEGIN
  v_percent := public.get_purchase_commission_percent();

  RETURN QUERY SELECT
    v_percent AS commission_percent,
    ROUND(p_amount * v_percent / 100, 2) AS commission_amount,
    ROUND(p_amount - (p_amount * v_percent / 100), 2) AS amount_after_commission;
END;
$$;

-- 5. S'assurer que les valeurs par défaut existent dans system_settings
INSERT INTO public.system_settings (setting_key, setting_value, description, created_at, updated_at)
VALUES
  ('purchase_fee_percent', '10', 'Taux de commission sur les achats marketplace (modifiable par le PDG)', NOW(), NOW()),
  ('service_fee_percent', '0.5', 'Taux de commission sur les services professionnels (modifiable par le PDG)', NOW(), NOW())
ON CONFLICT (setting_key) DO NOTHING;

-- 6. Synchroniser les valeurs actuelles de pdg_settings vers system_settings
DO $$
DECLARE
  v_purchase_fee NUMERIC;
  v_service_fee NUMERIC;
BEGIN
  -- Récupérer purchase_commission_percentage
  SELECT (setting_value->>'value')::NUMERIC INTO v_purchase_fee
  FROM pdg_settings
  WHERE setting_key = 'purchase_commission_percentage';

  IF v_purchase_fee IS NOT NULL THEN
    UPDATE system_settings
    SET setting_value = v_purchase_fee::TEXT, updated_at = NOW()
    WHERE setting_key = 'purchase_fee_percent';

    RAISE NOTICE 'Synchronisé: purchase_fee_percent = %', v_purchase_fee;
  END IF;

  -- Récupérer service_commissions (prendre la valeur 'value' ou un défaut)
  SELECT COALESCE(
    (setting_value->>'value')::NUMERIC,
    (setting_value->>'default')::NUMERIC,
    0.5
  ) INTO v_service_fee
  FROM pdg_settings
  WHERE setting_key = 'service_commissions';

  IF v_service_fee IS NOT NULL THEN
    UPDATE system_settings
    SET setting_value = v_service_fee::TEXT, updated_at = NOW()
    WHERE setting_key = 'service_fee_percent';

    RAISE NOTICE 'Synchronisé: service_fee_percent = %', v_service_fee;
  END IF;
END $$;

-- 7. Accorder les permissions
GRANT EXECUTE ON FUNCTION get_purchase_commission_percent() TO authenticated, service_role, anon;
GRANT EXECUTE ON FUNCTION get_service_commission_percent() TO authenticated, service_role, anon;
GRANT EXECUTE ON FUNCTION get_pdg_commission_config() TO authenticated, service_role, anon;
GRANT EXECUTE ON FUNCTION calculate_purchase_commission(NUMERIC) TO authenticated, service_role, anon;

-- 8. Corriger le trigger de synchronisation pour service_commissions
-- Le trigger existant attend 'default' mais l'interface envoie 'value'
CREATE OR REPLACE FUNCTION public.sync_pdg_settings_to_system_settings()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_new_value NUMERIC;
BEGIN
  -- Synchroniser wallet_transaction_fee_percentage -> transfer_fee_percent
  IF NEW.setting_key = 'wallet_transaction_fee_percentage' THEN
    v_new_value := (NEW.setting_value->>'value')::NUMERIC;

    UPDATE system_settings
    SET setting_value = v_new_value::TEXT,
        updated_at = NOW()
    WHERE setting_key = 'transfer_fee_percent';

    IF NOT FOUND THEN
      INSERT INTO system_settings (setting_key, setting_value, description)
      VALUES ('transfer_fee_percent', v_new_value::TEXT, 'Taux de commission pour les transferts entre wallets (en %)');
    END IF;

    RAISE NOTICE 'Synchronisé: wallet_transaction_fee_percentage = % vers transfer_fee_percent', v_new_value;
  END IF;

  -- Synchroniser purchase_commission_percentage -> purchase_fee_percent
  IF NEW.setting_key = 'purchase_commission_percentage' THEN
    v_new_value := (NEW.setting_value->>'value')::NUMERIC;

    UPDATE system_settings
    SET setting_value = v_new_value::TEXT,
        updated_at = NOW()
    WHERE setting_key = 'purchase_fee_percent';

    IF NOT FOUND THEN
      INSERT INTO system_settings (setting_key, setting_value, description)
      VALUES ('purchase_fee_percent', v_new_value::TEXT, 'Taux de commission sur les achats (en %)');
    END IF;

    RAISE NOTICE 'Synchronisé: purchase_commission_percentage = % vers purchase_fee_percent', v_new_value;
  END IF;

  -- Synchroniser service_commissions -> service_fee_percent
  -- CORRIGÉ: Lire 'value' au lieu de 'default'
  IF NEW.setting_key = 'service_commissions' THEN
    v_new_value := COALESCE(
      (NEW.setting_value->>'value')::NUMERIC,
      (NEW.setting_value->>'default')::NUMERIC,
      0.5
    );

    UPDATE system_settings
    SET setting_value = v_new_value::TEXT,
        updated_at = NOW()
    WHERE setting_key = 'service_fee_percent';

    IF NOT FOUND THEN
      INSERT INTO system_settings (setting_key, setting_value, description)
      VALUES ('service_fee_percent', v_new_value::TEXT, 'Taux de commission sur les services professionnels (en %)');
    END IF;

    RAISE NOTICE 'Synchronisé: service_commissions = % vers service_fee_percent', v_new_value;
  END IF;

  RETURN NEW;
END;
$$;

-- Recréer le trigger
DROP TRIGGER IF EXISTS trigger_sync_pdg_settings ON pdg_settings;
CREATE TRIGGER trigger_sync_pdg_settings
  AFTER INSERT OR UPDATE ON pdg_settings
  FOR EACH ROW
  EXECUTE FUNCTION sync_pdg_settings_to_system_settings();

-- 9. Commentaires
COMMENT ON FUNCTION get_purchase_commission_percent IS 'Retourne le taux de commission sur les achats marketplace depuis system_settings (modifiable par PDG)';
COMMENT ON FUNCTION get_service_commission_percent IS 'Retourne le taux de commission sur les services depuis system_settings (modifiable par PDG)';
COMMENT ON FUNCTION get_pdg_commission_config IS 'Retourne tous les taux de commission configurés par le PDG';
COMMENT ON FUNCTION calculate_purchase_commission IS 'Calcule la commission PDG sur un achat marketplace';
COMMENT ON FUNCTION sync_pdg_settings_to_system_settings IS 'Trigger qui synchronise pdg_settings vers system_settings quand les taux sont modifiés';
