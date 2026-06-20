
-- =====================================================
-- RLS BULK FIX: Change all 'public' role policies to 'authenticated'
-- This is a comprehensive fix using a DO block
-- =====================================================

DO $$
DECLARE
  policy_record RECORD;
  policy_roles text[];
  table_name_var text;
  policy_name_var text;
  policy_cmd text;
  policy_qual text;
  policy_with_check text;
BEGIN
  -- Loop through all policies with 'public' role
  FOR policy_record IN 
    SELECT 
      schemaname,
      tablename,
      policyname,
      cmd,
      roles,
      qual,
      with_check
    FROM pg_policies 
    WHERE schemaname = 'public' 
    AND 'public' = ANY(roles)
  LOOP
    table_name_var := policy_record.tablename;
    policy_name_var := policy_record.policyname;
    
    -- Skip service_role policies (they need public)
    IF position('service' IN lower(policy_name_var)) > 0 OR
       position('Service' IN policy_name_var) > 0 THEN
      -- Replace public with service_role
      EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', policy_name_var, table_name_var);
      
      IF policy_record.cmd = 'ALL' THEN
        EXECUTE format('CREATE POLICY %I ON public.%I FOR ALL TO service_role USING (true) WITH CHECK (true)', policy_name_var, table_name_var);
      ELSIF policy_record.cmd = 'SELECT' THEN
        EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO service_role USING (true)', policy_name_var, table_name_var);
      ELSIF policy_record.cmd = 'INSERT' THEN
        EXECUTE format('CREATE POLICY %I ON public.%I FOR INSERT TO service_role WITH CHECK (true)', policy_name_var, table_name_var);
      ELSIF policy_record.cmd = 'UPDATE' THEN
        EXECUTE format('CREATE POLICY %I ON public.%I FOR UPDATE TO service_role USING (true) WITH CHECK (true)', policy_name_var, table_name_var);
      ELSIF policy_record.cmd = 'DELETE' THEN
        EXECUTE format('CREATE POLICY %I ON public.%I FOR DELETE TO service_role USING (true)', policy_name_var, table_name_var);
      END IF;
    ELSE
      -- Replace public with authenticated
      EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', policy_name_var, table_name_var);
      
      IF policy_record.cmd = 'ALL' THEN
        EXECUTE format('CREATE POLICY %I ON public.%I FOR ALL TO authenticated USING (true) WITH CHECK (true)', policy_name_var, table_name_var);
      ELSIF policy_record.cmd = 'SELECT' THEN
        EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (true)', policy_name_var, table_name_var);
      ELSIF policy_record.cmd = 'INSERT' THEN
        EXECUTE format('CREATE POLICY %I ON public.%I FOR INSERT TO authenticated WITH CHECK (true)', policy_name_var, table_name_var);
      ELSIF policy_record.cmd = 'UPDATE' THEN
        EXECUTE format('CREATE POLICY %I ON public.%I FOR UPDATE TO authenticated USING (true) WITH CHECK (true)', policy_name_var, table_name_var);
      ELSIF policy_record.cmd = 'DELETE' THEN
        EXECUTE format('CREATE POLICY %I ON public.%I FOR DELETE TO authenticated USING (true)', policy_name_var, table_name_var);
      END IF;
    END IF;
  END LOOP;
END $$;
