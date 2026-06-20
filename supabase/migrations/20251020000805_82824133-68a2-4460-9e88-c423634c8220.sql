-- Corriger le search_path pour la fonction update_updated_at_column
DROP FUNCTION IF EXISTS update_updated_at_column() CASCADE;

CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

-- Recréer les triggers
CREATE TRIGGER update_syndicate_workers_updated_at
  BEFORE UPDATE ON public.syndicate_workers
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_bureau_features_updated_at
  BEFORE UPDATE ON public.bureau_features
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

-- Activer RLS sur bureau_feature_assignments
ALTER TABLE public.bureau_feature_assignments ENABLE ROW LEVEL SECURITY;

-- Policies pour bureau_feature_assignments
CREATE POLICY "Admins can manage feature assignments"
ON public.bureau_feature_assignments FOR ALL
TO authenticated
USING (EXISTS (
  SELECT 1 FROM public.profiles
  WHERE profiles.id = auth.uid()
  AND profiles.role = 'admin'
));

CREATE POLICY "Bureau presidents can view their assignments"
ON public.bureau_feature_assignments FOR SELECT
TO authenticated
USING (
  bureau_id IN (
    SELECT id FROM public.bureaus 
    WHERE president_email = auth.jwt()->>'email'
  )
);