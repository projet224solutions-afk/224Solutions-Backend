-- =====================================================
-- CORRECTION DES POLITIQUES RLS POUR SYSTEM_SETTINGS ET PDG_SETTINGS
-- + SYNCHRONISATION DES TAUX DE COMMISSION ENTRE LES DEUX TABLES
-- 224SOLUTIONS - 29 Janvier 2026
-- =====================================================
-- Problèmes identifiés:
-- 1. Le PDG ne peut pas modifier les taux de frais (politique UPDATE exigeait role='admin')
-- 2. pdg_settings.wallet_transaction_fee_percentage n'est PAS synchronisé avec 
--    system_settings.transfer_fee_percent (utilisé par les fonctions SQL)
-- =====================================================

-- 1. Fonction helper pour vérifier si l'utilisateur est PDG
CREATE OR REPLACE FUNCTION public.is_pdg_user()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_user_id UUID;
  v_is_pdg BOOLEAN := FALSE;
BEGIN
  v_user_id := auth.uid();
  
  IF v_user_id IS NULL THEN
    RETURN FALSE;
  END IF;
  
  -- Vérifier dans pdg_management
  SELECT EXISTS(
    SELECT 1 FROM pdg_management 
    WHERE user_id = v_user_id 
    AND is_active = true
  ) INTO v_is_pdg;
  
  IF v_is_pdg THEN
    RETURN TRUE;
  END IF;
  
  -- Sinon vérifier le rôle dans profiles
  SELECT EXISTS(
    SELECT 1 FROM profiles 
    WHERE id = v_user_id 
    AND role::text IN ('admin', 'ceo', 'pdg', 'PDG', 'CEO', 'ADMIN')
  ) INTO v_is_pdg;
  
  RETURN v_is_pdg;
END;
$$;

-- =====================================================
-- 2. TRIGGER POUR SYNCHRONISER LES TAUX ENTRE pdg_settings ET system_settings
-- =====================================================

-- Fonction trigger pour synchroniser les taux quand pdg_settings est modifié
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
    
    -- Si pas trouvé, l'insérer
    IF NOT FOUND THEN
      INSERT INTO system_settings (setting_key, setting_value, description)
      VALUES ('transfer_fee_percent', v_new_value::TEXT, 'Taux de commission pour les transferts entre wallets (en %)');
    END IF;
    
    RAISE NOTICE 'Synchronisé: wallet_transaction_fee_percentage = % vers transfer_fee_percent', v_new_value;
  END IF;
  
  -- Synchroniser purchase_commission_percentage -> purchase_fee_percent (si existe)
  IF NEW.setting_key = 'purchase_commission_percentage' THEN
    v_new_value := (NEW.setting_value->>'value')::NUMERIC;
    
    UPDATE system_settings
    SET setting_value = v_new_value::TEXT,
        updated_at = NOW()
    WHERE setting_key = 'purchase_fee_percent';
    
    -- Si pas trouvé, l'insérer
    IF NOT FOUND THEN
      INSERT INTO system_settings (setting_key, setting_value, description)
      VALUES ('purchase_fee_percent', v_new_value::TEXT, 'Taux de commission sur les achats (en %)');
    END IF;
    
    RAISE NOTICE 'Synchronisé: purchase_commission_percentage = % vers purchase_fee_percent', v_new_value;
  END IF;
  
  -- Synchroniser service_commissions -> service_fee_percent
  IF NEW.setting_key = 'service_commissions' THEN
    v_new_value := COALESCE((NEW.setting_value->>'default')::NUMERIC, 5);
    
    UPDATE system_settings
    SET setting_value = v_new_value::TEXT,
        updated_at = NOW()
    WHERE setting_key = 'service_fee_percent';
    
    IF NOT FOUND THEN
      INSERT INTO system_settings (setting_key, setting_value, description)
      VALUES ('service_fee_percent', v_new_value::TEXT, 'Taux de commission sur les services professionnels (en %)');
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$;

-- Créer le trigger
DROP TRIGGER IF EXISTS trigger_sync_pdg_settings ON pdg_settings;
CREATE TRIGGER trigger_sync_pdg_settings
  AFTER INSERT OR UPDATE ON pdg_settings
  FOR EACH ROW
  EXECUTE FUNCTION sync_pdg_settings_to_system_settings();

-- =====================================================
-- 3. SYNCHRONISATION INITIALE: Prendre les valeurs de pdg_settings et les mettre dans system_settings
-- =====================================================

DO $$
DECLARE
  v_wallet_fee NUMERIC;
  v_purchase_fee NUMERIC;
  v_service_fee NUMERIC;
BEGIN
  -- Récupérer la valeur actuelle de wallet_transaction_fee_percentage dans pdg_settings
  SELECT (setting_value->>'value')::NUMERIC INTO v_wallet_fee
  FROM pdg_settings
  WHERE setting_key = 'wallet_transaction_fee_percentage';
  
  IF v_wallet_fee IS NOT NULL THEN
    UPDATE system_settings
    SET setting_value = v_wallet_fee::TEXT,
        updated_at = NOW()
    WHERE setting_key = 'transfer_fee_percent';
    
    RAISE NOTICE 'Synchronisation initiale: transfer_fee_percent = %', v_wallet_fee;
  END IF;
  
  -- Récupérer purchase_commission_percentage
  SELECT (setting_value->>'value')::NUMERIC INTO v_purchase_fee
  FROM pdg_settings
  WHERE setting_key = 'purchase_commission_percentage';
  
  IF v_purchase_fee IS NOT NULL THEN
    INSERT INTO system_settings (setting_key, setting_value, description)
    VALUES ('purchase_fee_percent', v_purchase_fee::TEXT, 'Taux de commission sur les achats (en %)')
    ON CONFLICT (setting_key) DO UPDATE SET 
      setting_value = EXCLUDED.setting_value,
      updated_at = NOW();
    
    RAISE NOTICE 'Synchronisation initiale: purchase_fee_percent = %', v_purchase_fee;
  END IF;
END $$;

-- =====================================================
-- 4. CORRECTION DES POLITIQUES POUR system_settings
-- =====================================================

-- Supprimer les anciennes politiques
DROP POLICY IF EXISTS "Anyone can view system settings" ON system_settings;
DROP POLICY IF EXISTS "Only PDG can update system settings" ON system_settings;
DROP POLICY IF EXISTS "PDG can view system settings" ON system_settings;
DROP POLICY IF EXISTS "PDG can update system settings" ON system_settings;
DROP POLICY IF EXISTS "PDG can insert system settings" ON system_settings;
DROP POLICY IF EXISTS "PDG can delete system settings" ON system_settings;
DROP POLICY IF EXISTS "Authenticated users can view system settings" ON system_settings;
DROP POLICY IF EXISTS "Service role full access to system settings" ON system_settings;

-- Créer les nouvelles politiques complètes

-- SELECT: Tous les utilisateurs authentifiés peuvent lire
CREATE POLICY "Authenticated users can view system settings"
ON system_settings FOR SELECT
TO authenticated
USING (true);

-- UPDATE: Seul le PDG peut modifier
CREATE POLICY "PDG can update system settings"
ON system_settings FOR UPDATE
TO authenticated
USING (is_pdg_user())
WITH CHECK (is_pdg_user());

-- INSERT: Seul le PDG peut créer
CREATE POLICY "PDG can insert system settings"
ON system_settings FOR INSERT
TO authenticated
WITH CHECK (is_pdg_user());

-- DELETE: Seul le PDG peut supprimer
CREATE POLICY "PDG can delete system settings"
ON system_settings FOR DELETE
TO authenticated
USING (is_pdg_user());

-- Politique pour service_role (backend)
CREATE POLICY "Service role full access to system settings"
ON system_settings FOR ALL
TO service_role
USING (true)
WITH CHECK (true);

-- =====================================================
-- 5. CORRECTION DES POLITIQUES POUR pdg_settings
-- =====================================================

-- Supprimer les anciennes politiques
DROP POLICY IF EXISTS "Admins can view pdg_settings" ON pdg_settings;
DROP POLICY IF EXISTS "Admins can update pdg_settings" ON pdg_settings;
DROP POLICY IF EXISTS "Admins can insert pdg_settings" ON pdg_settings;
DROP POLICY IF EXISTS "PDG can view pdg_settings" ON pdg_settings;
DROP POLICY IF EXISTS "PDG can update pdg_settings" ON pdg_settings;
DROP POLICY IF EXISTS "PDG can insert pdg_settings" ON pdg_settings;
DROP POLICY IF EXISTS "PDG can delete pdg_settings" ON pdg_settings;
DROP POLICY IF EXISTS "Service role full access to pdg_settings" ON pdg_settings;

-- Créer les nouvelles politiques

-- SELECT: PDG peut lire
CREATE POLICY "PDG can view pdg_settings"
ON pdg_settings FOR SELECT
TO authenticated
USING (is_pdg_user());

-- UPDATE: PDG peut modifier
CREATE POLICY "PDG can update pdg_settings"
ON pdg_settings FOR UPDATE
TO authenticated
USING (is_pdg_user())
WITH CHECK (is_pdg_user());

-- INSERT: PDG peut créer
CREATE POLICY "PDG can insert pdg_settings"
ON pdg_settings FOR INSERT
TO authenticated
WITH CHECK (is_pdg_user());

-- DELETE: PDG peut supprimer
CREATE POLICY "PDG can delete pdg_settings"
ON pdg_settings FOR DELETE
TO authenticated
USING (is_pdg_user());

-- Politique pour service_role (backend)
CREATE POLICY "Service role full access to pdg_settings"
ON pdg_settings FOR ALL
TO service_role
USING (true)
WITH CHECK (true);

-- =====================================================
-- 6. Grant execute sur la fonction helper
-- =====================================================
GRANT EXECUTE ON FUNCTION is_pdg_user() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION sync_pdg_settings_to_system_settings() TO service_role;

-- =====================================================
-- 7. Assurer que RLS est activé sur les deux tables
-- =====================================================
ALTER TABLE system_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE pdg_settings ENABLE ROW LEVEL SECURITY;

-- =====================================================
-- 8. Commentaires
-- =====================================================
COMMENT ON FUNCTION is_pdg_user IS 'Vérifie si l''utilisateur actuel est un PDG (via pdg_management ou rôle admin/ceo)';
COMMENT ON FUNCTION sync_pdg_settings_to_system_settings IS 'Trigger qui synchronise automatiquement pdg_settings vers system_settings quand les taux sont modifiés';
