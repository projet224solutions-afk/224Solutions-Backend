-- 🔑 ACCÈS AGENT VENDEUR — policies RLS additives is_vendor_or_agent sur les tables du
-- vendeur dont l'accès était propriétaire-SEUL (vendors.user_id = auth.uid()), ce qui
-- BLOQUAIT l'agent vendeur (qui interroge Supabase directement depuis son interface).
--
-- Additif/sûr : on AJOUTE une policy `<t>_agent_access` (FOR ALL, is_vendor_or_agent(vendor_id)).
-- Les policies propriétaire existantes restent (le vendeur garde son accès) ; les policies
-- étant combinées en OR, on ne fait qu'ÉTENDRE l'accès aux agents ACTIFS du vendeur.
-- Les étrangers restent bloqués (is_vendor_or_agent = false). vendor_id = vendors.id confirmé
-- (FK→vendors ou policy existante référençant vendors.id) pour toutes ces tables.

DO $$
DECLARE
  v_table text;
  v_tables text[] := ARRAY[
    'stock_purchases','stock_losses','stock_transfers','stock_adjustments','location_stock_movements',
    'inventory_history','locations','vendor_locations','grouped_sales','sale_returns',
    'vendor_marketing_contacts','vendor_customer_links','vendor_campaigns','vendor_campaign_audit_logs',
    'vendor_campaign_quotas','vendor_campaign_recipients','customer_credits','vendor_credit_sales',
    'installment_plans','contact_statements','vendor_collection_accounts','clients','quotes','invoices',
    'deliveries','digital_products','wishlists','advanced_carts','checkout_rate_locks','support_tickets',
    'expense_analytics','vendor_fixed_costs','vendor_promotions','shop_visits_raw','currency_conversion_logs',
    'vendor_ai_documents','vendor_ai_execution_logs',
    'dropship_settings','dropship_products','dropship_orders','dropship_incidents','dropship_reports'
  ];
BEGIN
  FOREACH v_table IN ARRAY v_tables LOOP
    -- ne traiter que si la table existe et n'a pas déjà une policy is_vendor_or_agent
    IF to_regclass('public.' || v_table) IS NOT NULL
       AND NOT EXISTS (
         SELECT 1 FROM pg_policies
         WHERE schemaname='public' AND tablename=v_table
           AND (COALESCE(qual,'') || COALESCE(with_check,'')) LIKE '%is_vendor_or_agent%'
       )
    THEN
      EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', v_table || '_agent_access', v_table);
      EXECUTE format(
        'CREATE POLICY %I ON public.%I FOR ALL TO authenticated USING (public.is_vendor_or_agent(vendor_id)) WITH CHECK (public.is_vendor_or_agent(vendor_id))',
        v_table || '_agent_access', v_table
      );
    END IF;
  END LOOP;
END $$;
