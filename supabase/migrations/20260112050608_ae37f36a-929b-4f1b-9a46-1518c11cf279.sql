-- Fix RLS for professional_services: allow authenticated vendors to manage their own services

ALTER TABLE public.professional_services ENABLE ROW LEVEL SECURITY;

-- Allow authenticated users to view their own services (any status)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies 
    WHERE schemaname='public' AND tablename='professional_services' AND policyname='Authenticated users can view own professional services'
  ) THEN
    CREATE POLICY "Authenticated users can view own professional services"
    ON public.professional_services
    FOR SELECT
    TO authenticated
    USING (auth.uid() = user_id);
  END IF;
END $$;

-- Allow authenticated users to create their own services
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies 
    WHERE schemaname='public' AND tablename='professional_services' AND policyname='Authenticated users can create own professional services'
  ) THEN
    CREATE POLICY "Authenticated users can create own professional services"
    ON public.professional_services
    FOR INSERT
    TO authenticated
    WITH CHECK (auth.uid() = user_id);
  END IF;
END $$;

-- Allow authenticated users to update their own services
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies 
    WHERE schemaname='public' AND tablename='professional_services' AND policyname='Authenticated users can update own professional services'
  ) THEN
    CREATE POLICY "Authenticated users can update own professional services"
    ON public.professional_services
    FOR UPDATE
    TO authenticated
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);
  END IF;
END $$;

-- Allow authenticated users to delete their own services
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies 
    WHERE schemaname='public' AND tablename='professional_services' AND policyname='Authenticated users can delete own professional services'
  ) THEN
    CREATE POLICY "Authenticated users can delete own professional services"
    ON public.professional_services
    FOR DELETE
    TO authenticated
    USING (auth.uid() = user_id);
  END IF;
END $$;