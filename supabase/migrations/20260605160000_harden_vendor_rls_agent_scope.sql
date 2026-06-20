-- 🔒 DURCISSEMENT RLS — données vendeur privées : scope au vendeur + ses agents actifs.
--
-- Problème : plusieurs tables CRM vendeur avaient une policy permissive `USING true /
-- WITH CHECK true` pour le rôle `authenticated` → N'IMPORTE QUEL utilisateur connecté
-- pouvait lire/écrire les données de N'IMPORTE QUEL vendeur (trou de sécurité). C'était
-- aussi ce qui laissait passer l'agent du vendeur (effet de bord).
--
-- Correctif : remplacer la policy permissive par une policy basée sur la fonction
-- existante `public.is_vendor_or_agent(vendor_id)` = (vendeur propriétaire) OU
-- (agent actif de ce vendeur). Garde l'accès vendeur + agent, bloque les étrangers.
--
-- Tables traitées : uniquement celles dont `vendor_id` a une FK propre vers `vendors`
-- (sémantique non ambiguë). Les tables sans FK (pos_settings, expense_*) sont exclues.
-- Les policies SELECT publiques (marketplace) et les policies admin ne sont pas touchées.

DO $$
DECLARE
  v_table text;
  v_tables text[] := ARRAY[
    'prospects', 'marketing_campaigns', 'promo_codes', 'promotions',
    'interactions', 'inventory_alerts', 'sales', 'shipments'
  ];
  -- noms exacts des policies permissives `true` à supprimer
  v_perms jsonb := jsonb_build_object(
    'prospects',           jsonb_build_array('Vendors can manage their prospects'),
    'marketing_campaigns', jsonb_build_array('Vendors can manage their campaigns'),
    'promo_codes',         jsonb_build_array('Vendors can manage their promo codes'),
    'promotions',          jsonb_build_array('Vendors can manage their promotions'),
    'interactions',        jsonb_build_array('Vendors can manage their interactions'),
    'inventory_alerts',    jsonb_build_array('Vendors can manage their inventory alerts'),
    'sales',               jsonb_build_array('Vendors can insert their own sales'),
    'shipments',           jsonb_build_array('Vendors can delete their own shipments', 'Vendors can create shipments', 'Vendors can update their own shipments')
  );
  v_pname text;
BEGIN
  FOREACH v_table IN ARRAY v_tables LOOP
    -- 1) supprimer les policies permissives `true`
    FOR v_pname IN SELECT jsonb_array_elements_text(v_perms -> v_table) LOOP
      EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', v_pname, v_table);
    END LOOP;

    -- 2) (re)créer la policy scoped vendeur+agent (idempotent)
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', v_table || '_vendor_agent_manage', v_table);
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR ALL TO authenticated USING (public.is_vendor_or_agent(vendor_id) OR public.is_admin()) WITH CHECK (public.is_vendor_or_agent(vendor_id) OR public.is_admin())',
      v_table || '_vendor_agent_manage', v_table
    );
  END LOOP;
END $$;
