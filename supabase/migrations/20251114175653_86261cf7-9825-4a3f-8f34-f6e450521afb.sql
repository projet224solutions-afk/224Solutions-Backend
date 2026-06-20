-- Corriger les politiques RLS pour l'interface PDG Syndicat
-- Permettre l'accès aux PDG (via pdg_management) ET aux admins (via profiles.role)

-- 1. Corriger syndicate_workers
DROP POLICY IF EXISTS "PDG view all workers" ON public.syndicate_workers;
DROP POLICY IF EXISTS "PDG manage workers" ON public.syndicate_workers;

CREATE POLICY "PDG and Admins view all workers" 
ON public.syndicate_workers FOR SELECT
TO public
USING (
  EXISTS (
    SELECT 1 FROM pdg_management WHERE pdg_management.user_id = auth.uid()
  )
  OR
  EXISTS (
    SELECT 1 FROM profiles WHERE profiles.id = auth.uid() AND profiles.role = 'admin'
  )
);

CREATE POLICY "PDG and Admins manage workers" 
ON public.syndicate_workers FOR ALL
TO public
USING (
  EXISTS (
    SELECT 1 FROM pdg_management WHERE pdg_management.user_id = auth.uid()
  )
  OR
  EXISTS (
    SELECT 1 FROM profiles WHERE profiles.id = auth.uid() AND profiles.role = 'admin'
  )
);

-- 2. Corriger syndicate_alerts
DROP POLICY IF EXISTS "Admins can view all alerts" ON public.syndicate_alerts;

CREATE POLICY "PDG and Admins view all alerts" 
ON public.syndicate_alerts FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM pdg_management WHERE pdg_management.user_id = auth.uid()
  )
  OR
  EXISTS (
    SELECT 1 FROM profiles WHERE profiles.id = auth.uid() AND profiles.role = 'admin'
  )
);

CREATE POLICY "PDG and Admins manage alerts" 
ON public.syndicate_alerts FOR ALL
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM pdg_management WHERE pdg_management.user_id = auth.uid()
  )
  OR
  EXISTS (
    SELECT 1 FROM profiles WHERE profiles.id = auth.uid() AND profiles.role = 'admin'
  )
);

-- 3. Corriger bureau_features pour inclure aussi les PDG
DROP POLICY IF EXISTS "Admins can manage features" ON public.bureau_features;

CREATE POLICY "PDG and Admins manage features" 
ON public.bureau_features FOR ALL
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM pdg_management WHERE pdg_management.user_id = auth.uid()
  )
  OR
  EXISTS (
    SELECT 1 FROM profiles WHERE profiles.id = auth.uid() AND profiles.role = 'admin'
  )
);

-- 4. S'assurer que les tables ont RLS activé
ALTER TABLE public.syndicate_workers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.syndicate_alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bureau_features ENABLE ROW LEVEL SECURITY;