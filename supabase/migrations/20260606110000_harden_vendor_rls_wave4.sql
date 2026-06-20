-- 🔒 DURCISSEMENT RLS — vague 4 (finale CRM/vendeur). Clôt les dernières policies `true`.

-- ── Groupe A : tables vendeur-scoped (vendor_id = vendors.id) → is_vendor_or_agent + admin.
DO $$
DECLARE
  r record;
  v_map jsonb := jsonb_build_object(
    'suppliers',                       'Vendors can manage their suppliers',
    'warehouses',                      'Vendors can manage their warehouses',
    'vendor_employees',                'Vendors can manage their employees',
    'vendor_preferred_drivers',        'Vendors can manage their preferred drivers',
    'vendor_transactions',             'Vendors can insert their own transactions',
    'vendor_ai_control',               'Vendors can update own AI control',
    'vendor_ai_decisions',             'Vendors can update own AI decisions',
    'vendor_ai_marketing_campaigns',   'Vendors can update own marketing campaigns',
    'vendor_review_sentiment_analysis','Vendors can update own sentiment analysis',
    'vendor_stock_ai_alerts',          'Vendors can update own stock alerts'
  );
  v_table text;
BEGIN
  FOR v_table IN SELECT jsonb_object_keys(v_map) LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', v_map ->> v_table, v_table);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', v_table || '_vendor_agent_manage', v_table);
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR ALL TO authenticated USING (public.is_vendor_or_agent(vendor_id) OR public.is_admin()) WITH CHECK (public.is_vendor_or_agent(vendor_id) OR public.is_admin())',
      v_table || '_vendor_agent_manage', v_table
    );
  END LOOP;
END $$;

-- ── Groupe B : vendor_id → profiles.id (= l'utilisateur). Données sensibles/personnelles :
--    scope au propriétaire (vendeur) + admin. PAS d'agent (KYC/notifications personnelles).
--    vendor_kyc : ferme aussi la fuite SELECT (tout le monde voyait tous les KYC).
DROP POLICY IF EXISTS "Vendors can insert their own KYC" ON public.vendor_kyc;
DROP POLICY IF EXISTS "Vendors can view their own KYC" ON public.vendor_kyc;
DROP POLICY IF EXISTS "Vendors can update their own KYC" ON public.vendor_kyc;
DROP POLICY IF EXISTS "vendor_kyc_owner" ON public.vendor_kyc;
CREATE POLICY "vendor_kyc_owner" ON public.vendor_kyc
  FOR ALL TO authenticated
  USING (vendor_id = auth.uid() OR public.is_admin())
  WITH CHECK (vendor_id = auth.uid() OR public.is_admin());

-- vendor_notifications : ferme la fuite SELECT + l'UPDATE permissif. On garde l'INSERT
-- public ("System can create...") car les notifications sont créées par le système.
DROP POLICY IF EXISTS "Vendors can view their own notifications" ON public.vendor_notifications;
DROP POLICY IF EXISTS "Vendors can update their own notifications" ON public.vendor_notifications;
DROP POLICY IF EXISTS "vendor_notifications_owner" ON public.vendor_notifications;
CREATE POLICY "vendor_notifications_owner" ON public.vendor_notifications
  FOR ALL TO authenticated
  USING (vendor_id = auth.uid() OR public.is_admin())
  WITH CHECK (vendor_id = auth.uid() OR public.is_admin());

-- ── Groupe C : vendor_ratings = avis CLIENT. Le client gère sa note ; lecture publique
--    conservée ("Les notes sont visibles par tous").
DROP POLICY IF EXISTS "Les clients peuvent noter leurs commandes" ON public.vendor_ratings;
DROP POLICY IF EXISTS "Les clients peuvent modifier leurs notes" ON public.vendor_ratings;
DROP POLICY IF EXISTS "vendor_ratings_customer_manage" ON public.vendor_ratings;
CREATE POLICY "vendor_ratings_customer_manage" ON public.vendor_ratings
  FOR ALL TO authenticated
  USING (customer_id = auth.uid() OR public.is_admin())
  WITH CHECK (customer_id = auth.uid() OR public.is_admin());
