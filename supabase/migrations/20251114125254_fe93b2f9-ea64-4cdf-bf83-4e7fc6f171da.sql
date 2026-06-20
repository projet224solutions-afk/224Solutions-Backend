-- 🔒 CORRECTION SÉCURITÉ CRITIQUE v3
-- Date: 2025-11-14
-- Correction enum user_role

-- 1. CORRECTION CRITIQUE: Wallets - Restriction accès données financières
DROP POLICY IF EXISTS "Users can view other wallets for transfers" ON public.wallets;
DROP POLICY IF EXISTS "Users can view own wallet only" ON public.wallets;

-- Nouvelle politique: Les utilisateurs ne voient que leur propre wallet
CREATE POLICY "Users can view own wallet only"
ON public.wallets
FOR SELECT
USING (auth.uid() = user_id);

-- Fonction sécurisée pour vérifier l'existence d'un wallet lors des transferts
CREATE OR REPLACE FUNCTION public.verify_wallet_exists(target_user_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.wallets
    WHERE user_id = target_user_id
    AND status = 'active'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.verify_wallet_exists(UUID) TO authenticated;

COMMENT ON FUNCTION public.verify_wallet_exists IS 'Vérifie existence wallet sans exposer les données financières';

-- 2. CORRECTION CRITIQUE: platform_settings - Activer RLS
ALTER TABLE public.platform_settings ENABLE ROW LEVEL SECURITY;

-- Supprimer toutes les politiques existantes
DROP POLICY IF EXISTS "authenticated_read" ON public.platform_settings;
DROP POLICY IF EXISTS "public_read" ON public.platform_settings;
DROP POLICY IF EXISTS "service_role_all_access" ON public.platform_settings;
DROP POLICY IF EXISTS "admins_read_only" ON public.platform_settings;

-- Service role uniquement peut tout faire
CREATE POLICY "service_role_all_access"
ON public.platform_settings
FOR ALL
USING (auth.role() = 'service_role')
WITH CHECK (auth.role() = 'service_role');

-- CEO et admins peuvent seulement lire
CREATE POLICY "admins_read_only"
ON public.platform_settings
FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid()
    AND role IN ('ceo', 'admin')
  )
);

-- Fonction sécurisée pour obtenir des paramètres publics non-sensibles
CREATE OR REPLACE FUNCTION public.get_public_setting(setting_key TEXT)
RETURNS TEXT
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT value 
  FROM public.platform_settings
  WHERE key = setting_key
    AND key IN ('app_name', 'support_email', 'maintenance_mode', 'version');
$$;

GRANT EXECUTE ON FUNCTION public.get_public_setting(TEXT) TO authenticated, anon;

COMMENT ON TABLE public.platform_settings IS '🔒 RLS enabled - Configuration système protégée';
COMMENT ON FUNCTION public.get_public_setting IS 'Accès sécurisé aux paramètres publics uniquement';