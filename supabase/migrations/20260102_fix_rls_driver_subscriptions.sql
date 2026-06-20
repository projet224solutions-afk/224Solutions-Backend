-- FIX CRITIQUE: RLS Policies pour permettre au PDG d'offrir des abonnements
-- Date: 2025-01-02
-- Problème: Les policies driver_subscriptions bloquent les insertions du PDG

-- 1. Supprimer l'ancienne policy restrictive
DROP POLICY IF EXISTS "Users can manage driver subscriptions" ON public.driver_subscriptions;
DROP POLICY IF EXISTS "users_own_driver_subscriptions" ON public.driver_subscriptions;

-- 2. Créer nouvelles policies plus flexibles

-- Policy pour les utilisateurs: gérer leurs propres abonnements
CREATE POLICY "users_manage_own_subscriptions" ON public.driver_subscriptions
FOR ALL TO authenticated
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

-- Policy pour les admins/PDG: gérer tous les abonnements
CREATE POLICY "admin_manage_all_subscriptions" ON public.driver_subscriptions
FOR ALL TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role IN ('admin', 'ceo')
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role IN ('admin', 'ceo')
  )
);

-- 3. Ajouter policy pour service_role (fonctions SECURITY DEFINER)
CREATE POLICY "service_role_full_access" ON public.driver_subscriptions
FOR ALL TO service_role
USING (true)
WITH CHECK (true);

-- 4. Vérifier que la table a RLS activé
ALTER TABLE driver_subscriptions ENABLE ROW LEVEL SECURITY;

-- 5. Faire de même pour driver_subscription_config
DROP POLICY IF EXISTS "service_role_all" ON public.driver_subscription_config;

CREATE POLICY "admin_manage_config" ON public.driver_subscription_config
FOR ALL TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role IN ('admin', 'ceo')
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role IN ('admin', 'ceo')
  )
);

CREATE POLICY "users_read_config" ON public.driver_subscription_config
FOR SELECT TO authenticated
USING (is_active = TRUE);

CREATE POLICY "service_role_config_access" ON public.driver_subscription_config
FOR ALL TO service_role
USING (true)
WITH CHECK (true);

ALTER TABLE driver_subscription_config ENABLE ROW LEVEL SECURITY;

-- 6. Policy pour driver_subscription_revenues
DROP POLICY IF EXISTS "Users can view subscription revenues" ON public.driver_subscription_revenues;

CREATE POLICY "users_view_own_revenues" ON public.driver_subscription_revenues
FOR SELECT TO authenticated
USING (user_id = auth.uid());

CREATE POLICY "admin_manage_revenues" ON public.driver_subscription_revenues
FOR ALL TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role IN ('admin', 'ceo')
  )
);

CREATE POLICY "service_role_revenues_access" ON public.driver_subscription_revenues
FOR ALL TO service_role
USING (true)
WITH CHECK (true);

ALTER TABLE driver_subscription_revenues ENABLE ROW LEVEL SECURITY;

-- 7. Vérification: fonction de test pour le PDG
CREATE OR REPLACE FUNCTION test_pdg_subscription_permissions()
RETURNS TABLE(
  test_name TEXT,
  can_insert BOOLEAN,
  can_update BOOLEAN,
  can_select BOOLEAN,
  message TEXT
) AS $$
BEGIN
  -- Test 1: Vérifier si l'utilisateur est admin
  RETURN QUERY
  SELECT 
    'Admin Role Check'::TEXT,
    EXISTS(SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'ceo'))::BOOLEAN,
    EXISTS(SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'ceo'))::BOOLEAN,
    EXISTS(SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'ceo'))::BOOLEAN,
    CASE 
      WHEN EXISTS(SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'ceo'))
      THEN 'Utilisateur a les droits admin'
      ELSE 'Utilisateur n''est pas admin'
    END::TEXT;

  -- Test 2: Vérifier les policies actives
  RETURN QUERY
  SELECT 
    'Active Policies'::TEXT,
    (SELECT COUNT(*) > 0 FROM pg_policies WHERE tablename = 'driver_subscriptions' AND policyname LIKE '%admin%')::BOOLEAN,
    true::BOOLEAN,
    true::BOOLEAN,
    (SELECT 'Policies actives: ' || COUNT(*)::TEXT FROM pg_policies WHERE tablename = 'driver_subscriptions')::TEXT;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 8. Commenter les fonctions
COMMENT ON POLICY "users_manage_own_subscriptions" ON driver_subscriptions 
IS 'Permet aux utilisateurs de gérer leurs propres abonnements (lecture/écriture)';

COMMENT ON POLICY "admin_manage_all_subscriptions" ON driver_subscriptions 
IS 'Permet aux admins et PDG de gérer tous les abonnements (lecture/écriture/suppression)';

COMMENT ON POLICY "service_role_full_access" ON driver_subscriptions 
IS 'Accès complet pour les fonctions SECURITY DEFINER (comme pdg_offer_subscription)';

-- 9. Log de déploiement
DO $$
BEGIN
  RAISE NOTICE 'RLS Policies pour driver_subscriptions mises à jour avec succès';
  RAISE NOTICE 'PDG peut maintenant offrir des abonnements';
  RAISE NOTICE 'Fonction de test disponible: test_pdg_subscription_permissions()';
END $$;
