-- Create enum for normalization reasons
DO $$ 
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'id_normalization_reason') THEN
    CREATE TYPE public.id_normalization_reason AS ENUM (
      'duplicate_detected',
      'format_invalid',
      'prefix_mismatch',
      'sequence_gap',
      'collision_resolved',
      'manual_override',
      'migration_fix'
    );
  END IF;
END $$;

-- Create the ID normalization audit log table
CREATE TABLE IF NOT EXISTS public.id_normalization_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  role_type TEXT NOT NULL,
  original_id TEXT NOT NULL,
  corrected_id TEXT NOT NULL,
  reason id_normalization_reason NOT NULL,
  reason_details JSONB DEFAULT '{}',
  auth_provider TEXT,
  ip_address INET,
  user_agent TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  metadata JSONB DEFAULT '{}'
);

-- Create indexes for efficient querying
CREATE INDEX IF NOT EXISTS idx_id_norm_logs_created_at ON public.id_normalization_logs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_id_norm_logs_role_type ON public.id_normalization_logs(role_type);
CREATE INDEX IF NOT EXISTS idx_id_norm_logs_reason ON public.id_normalization_logs(reason);
CREATE INDEX IF NOT EXISTS idx_id_norm_logs_user_id ON public.id_normalization_logs(user_id);

-- Enable RLS
ALTER TABLE public.id_normalization_logs ENABLE ROW LEVEL SECURITY;

-- RLS Policy: ONLY owners/CEOs can SELECT (read-only access)
CREATE POLICY "Only owners can view id normalization logs"
ON public.id_normalization_logs
FOR SELECT
TO authenticated
USING (public.is_owner(auth.uid()));

-- Create analytics view
CREATE OR REPLACE VIEW public.id_normalization_stats AS
SELECT 
  role_type,
  reason::text as reason,
  COUNT(*) as total_corrections,
  COUNT(DISTINCT user_id) as unique_users,
  DATE_TRUNC('day', created_at) as correction_date
FROM public.id_normalization_logs
GROUP BY role_type, reason, DATE_TRUNC('day', created_at);

-- Add documentation
COMMENT ON TABLE public.id_normalization_logs IS 'Audit log for automatic ID normalization. Read-only access for owners/CEOs only.';