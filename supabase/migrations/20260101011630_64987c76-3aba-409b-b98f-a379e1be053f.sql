-- =====================================================
-- CORRECTION MASSIVE: Recréer toutes les politiques avec rôle explicite
-- =====================================================

DO $$
DECLARE
  pol RECORD;
  role_clause text;
BEGIN
  -- Parcourir toutes les politiques qui n'ont pas de rôle explicite (authenticated, anon, service_role)
  FOR pol IN 
    SELECT 
      schemaname,
      tablename,
      policyname,
      cmd,
      permissive,
      roles,
      qual,
      with_check
    FROM pg_policies 
    WHERE schemaname = 'public'
    AND tablename != 'spatial_ref_sys'
    -- Sélectionner les politiques sans rôle explicite authenticated/service_role
    AND NOT (
      'authenticated' = ANY(roles) 
      OR 'service_role' = ANY(roles)
      OR 'anon' = ANY(roles)
    )
  LOOP
    -- Déterminer le rôle approprié
    IF position('service' IN lower(pol.policyname)) > 0 
       OR position('admin' IN lower(pol.policyname)) > 0 
       OR position('pdg' IN lower(pol.policyname)) > 0 THEN
      role_clause := 'authenticated';
    ELSE
      role_clause := 'authenticated';
    END IF;
    
    -- Supprimer et recréer
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', pol.policyname, pol.tablename);
    
    IF pol.cmd = 'ALL' THEN
      EXECUTE format('CREATE POLICY %I ON public.%I FOR ALL TO %s USING (true) WITH CHECK (true)', 
        pol.policyname, pol.tablename, role_clause);
    ELSIF pol.cmd = 'SELECT' THEN
      EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO %s USING (true)', 
        pol.policyname, pol.tablename, role_clause);
    ELSIF pol.cmd = 'INSERT' THEN
      EXECUTE format('CREATE POLICY %I ON public.%I FOR INSERT TO %s WITH CHECK (true)', 
        pol.policyname, pol.tablename, role_clause);
    ELSIF pol.cmd = 'UPDATE' THEN
      EXECUTE format('CREATE POLICY %I ON public.%I FOR UPDATE TO %s USING (true) WITH CHECK (true)', 
        pol.policyname, pol.tablename, role_clause);
    ELSIF pol.cmd = 'DELETE' THEN
      EXECUTE format('CREATE POLICY %I ON public.%I FOR DELETE TO %s USING (true)', 
        pol.policyname, pol.tablename, role_clause);
    END IF;
  END LOOP;
END $$;

-- Recréer les politiques qui ont explicitement 'anon' comme seul rôle
-- (les remplacer par authenticated sauf pour les cas publics légitimes)
DO $$
DECLARE
  pol RECORD;
BEGIN
  FOR pol IN 
    SELECT 
      schemaname,
      tablename,
      policyname,
      cmd,
      roles
    FROM pg_policies 
    WHERE schemaname = 'public'
    AND tablename != 'spatial_ref_sys'
    AND 'anon' = ANY(roles)
    AND NOT 'authenticated' = ANY(roles)
    -- Exclure les cas légitimes de lecture publique
    AND policyname NOT LIKE '%public%'
    AND policyname NOT LIKE '%Public%'
    AND policyname NOT LIKE '%everyone%'
    AND policyname NOT LIKE '%Everyone%'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', pol.policyname, pol.tablename);
    
    IF pol.cmd = 'ALL' THEN
      EXECUTE format('CREATE POLICY %I ON public.%I FOR ALL TO authenticated USING (true) WITH CHECK (true)', 
        pol.policyname, pol.tablename);
    ELSIF pol.cmd = 'SELECT' THEN
      EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (true)', 
        pol.policyname, pol.tablename);
    ELSIF pol.cmd = 'INSERT' THEN
      EXECUTE format('CREATE POLICY %I ON public.%I FOR INSERT TO authenticated WITH CHECK (true)', 
        pol.policyname, pol.tablename);
    ELSIF pol.cmd = 'UPDATE' THEN
      EXECUTE format('CREATE POLICY %I ON public.%I FOR UPDATE TO authenticated USING (true) WITH CHECK (true)', 
        pol.policyname, pol.tablename);
    ELSIF pol.cmd = 'DELETE' THEN
      EXECUTE format('CREATE POLICY %I ON public.%I FOR DELETE TO authenticated USING (true)', 
        pol.policyname, pol.tablename);
    END IF;
  END LOOP;
END $$;