-- Multi-cloud real monitoring schema
CREATE TABLE IF NOT EXISTS public.monitoring_providers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL UNIQUE,
  status text NOT NULL DEFAULT 'unknown' CHECK (status IN ('healthy','degraded','down','unknown')),
  latency integer,
  error_rate numeric(6,2) NOT NULL DEFAULT 0,
  last_check timestamp with time zone,
  uptime_percent numeric(6,2) NOT NULL DEFAULT 100,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.monitoring_services (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL UNIQUE,
  display_name text,
  provider_id uuid NOT NULL REFERENCES public.monitoring_providers(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'unknown' CHECK (status IN ('healthy','degraded','down','unknown')),
  latency integer,
  error_rate numeric(6,2) NOT NULL DEFAULT 0,
  requests_per_minute numeric(10,2) NOT NULL DEFAULT 0,
  check_count integer NOT NULL DEFAULT 0,
  fail_count integer NOT NULL DEFAULT 0,
  last_check timestamp with time zone,
  last_healthy_at timestamp with time zone,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.monitoring_incidents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_id uuid REFERENCES public.monitoring_providers(id) ON DELETE SET NULL,
  service_id uuid REFERENCES public.monitoring_services(id) ON DELETE SET NULL,
  severity text NOT NULL CHECK (severity IN ('low','medium','high','critical')),
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open','investigating','resolved')),
  title text NOT NULL,
  message text NOT NULL,
  dedupe_key text UNIQUE,
  occurrence_count integer NOT NULL DEFAULT 1,
  first_seen_at timestamp with time zone NOT NULL DEFAULT now(),
  last_seen_at timestamp with time zone NOT NULL DEFAULT now(),
  resolved_at timestamp with time zone,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_monitoring_services_provider_id ON public.monitoring_services(provider_id);
CREATE INDEX IF NOT EXISTS idx_monitoring_services_status ON public.monitoring_services(status);
CREATE INDEX IF NOT EXISTS idx_monitoring_incidents_status ON public.monitoring_incidents(status);
CREATE INDEX IF NOT EXISTS idx_monitoring_incidents_provider_id ON public.monitoring_incidents(provider_id);
CREATE INDEX IF NOT EXISTS idx_monitoring_incidents_service_id ON public.monitoring_incidents(service_id);

ALTER TABLE public.monitoring_providers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.monitoring_services ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.monitoring_incidents ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'monitoring_providers' AND policyname = 'admin_pdg_read_monitoring_providers'
  ) THEN
    CREATE POLICY admin_pdg_read_monitoring_providers
    ON public.monitoring_providers
    FOR SELECT
    TO authenticated
    USING (
      EXISTS (
        SELECT 1 FROM public.profiles
        WHERE profiles.id = auth.uid()
          AND profiles.role = ANY (ARRAY['admin'::user_role, 'pdg'::user_role])
      )
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'monitoring_providers' AND policyname = 'admin_pdg_write_monitoring_providers'
  ) THEN
    CREATE POLICY admin_pdg_write_monitoring_providers
    ON public.monitoring_providers
    FOR ALL
    TO authenticated
    USING (
      EXISTS (
        SELECT 1 FROM public.profiles
        WHERE profiles.id = auth.uid()
          AND profiles.role = ANY (ARRAY['admin'::user_role, 'pdg'::user_role])
      )
    )
    WITH CHECK (
      EXISTS (
        SELECT 1 FROM public.profiles
        WHERE profiles.id = auth.uid()
          AND profiles.role = ANY (ARRAY['admin'::user_role, 'pdg'::user_role])
      )
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'monitoring_services' AND policyname = 'admin_pdg_read_monitoring_services'
  ) THEN
    CREATE POLICY admin_pdg_read_monitoring_services
    ON public.monitoring_services
    FOR SELECT
    TO authenticated
    USING (
      EXISTS (
        SELECT 1 FROM public.profiles
        WHERE profiles.id = auth.uid()
          AND profiles.role = ANY (ARRAY['admin'::user_role, 'pdg'::user_role])
      )
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'monitoring_services' AND policyname = 'admin_pdg_write_monitoring_services'
  ) THEN
    CREATE POLICY admin_pdg_write_monitoring_services
    ON public.monitoring_services
    FOR ALL
    TO authenticated
    USING (
      EXISTS (
        SELECT 1 FROM public.profiles
        WHERE profiles.id = auth.uid()
          AND profiles.role = ANY (ARRAY['admin'::user_role, 'pdg'::user_role])
      )
    )
    WITH CHECK (
      EXISTS (
        SELECT 1 FROM public.profiles
        WHERE profiles.id = auth.uid()
          AND profiles.role = ANY (ARRAY['admin'::user_role, 'pdg'::user_role])
      )
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'monitoring_incidents' AND policyname = 'admin_pdg_read_monitoring_incidents'
  ) THEN
    CREATE POLICY admin_pdg_read_monitoring_incidents
    ON public.monitoring_incidents
    FOR SELECT
    TO authenticated
    USING (
      EXISTS (
        SELECT 1 FROM public.profiles
        WHERE profiles.id = auth.uid()
          AND profiles.role = ANY (ARRAY['admin'::user_role, 'pdg'::user_role])
      )
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'monitoring_incidents' AND policyname = 'admin_pdg_write_monitoring_incidents'
  ) THEN
    CREATE POLICY admin_pdg_write_monitoring_incidents
    ON public.monitoring_incidents
    FOR ALL
    TO authenticated
    USING (
      EXISTS (
        SELECT 1 FROM public.profiles
        WHERE profiles.id = auth.uid()
          AND profiles.role = ANY (ARRAY['admin'::user_role, 'pdg'::user_role])
      )
    )
    WITH CHECK (
      EXISTS (
        SELECT 1 FROM public.profiles
        WHERE profiles.id = auth.uid()
          AND profiles.role = ANY (ARRAY['admin'::user_role, 'pdg'::user_role])
      )
    );
  END IF;
END $$;