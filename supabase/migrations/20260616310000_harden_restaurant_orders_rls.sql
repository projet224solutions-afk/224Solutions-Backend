-- ============================================================================
-- DURCISSEMENT RLS — restaurant_orders (faille de confidentialité).
--
-- Révélé par le test d'isolation des agents restaurant : un utilisateur AUTHENTIFIÉ
-- quelconque pouvait lire TOUTES les commandes de TOUS les restaurants (clients,
-- montants, téléphones, adresses de livraison) → policy permissive `USING (true)`.
--
-- Fix chirurgical : supprimer toute policy de LECTURE permissive (qual = 'true') sur
-- restaurant_orders, sans toucher aux policies d'INSERT légitimes. Les bons accès restent
-- assurés par : owner/agent (is_service_owner_or_agent), client (customer_user_id=auth.uid()),
-- et le backend (service_role / RPC SECURITY DEFINER bypass RLS).
-- ============================================================================

DO $$
DECLARE pol record; n int := 0;
BEGIN
  FOR pol IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'restaurant_orders' AND qual = 'true'
  LOOP
    EXECUTE format('DROP POLICY %I ON public.restaurant_orders', pol.policyname);
    n := n + 1;
    RAISE NOTICE 'Policy permissive supprimée : %', pol.policyname;
  END LOOP;
  RAISE NOTICE '% policy(ies) permissive(s) supprimée(s) sur restaurant_orders.', n;
END $$;

-- Filets : garantir explicitement les accès légitimes (idempotent).
DROP POLICY IF EXISTS restaurant_orders_owner_agent ON public.restaurant_orders;
CREATE POLICY restaurant_orders_owner_agent ON public.restaurant_orders
  FOR ALL
  USING (public.is_service_owner_or_agent(professional_service_id))
  WITH CHECK (public.is_service_owner_or_agent(professional_service_id));

DROP POLICY IF EXISTS restaurant_orders_customer_read ON public.restaurant_orders;
CREATE POLICY restaurant_orders_customer_read ON public.restaurant_orders
  FOR SELECT
  USING (customer_user_id = auth.uid());

SELECT 'restaurant_orders durci : policies permissives (USING true) supprimées ; accès scopé owner/agent/client.' AS status;
