-- Corriger les politiques RLS pour l'interface PDG Syndicat (v2 - cleanup complet)

-- 1. Nettoyer toutes les anciennes politiques pour syndicate_workers
DROP POLICY IF EXISTS "PDG view all workers" ON public.syndicate_workers;
DROP POLICY IF EXISTS "PDG manage workers" ON public.syndicate_workers;
DROP POLICY IF EXISTS "PDG and Admins view all workers" ON public.syndicate_workers;
DROP POLICY IF EXISTS "PDG and Admins manage workers" ON public.syndicate_workers;

-- Recréer les politiques pour syndicate_workers
CREATE POLICY "PDG and Admins view all workers v2" 
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

CREATE POLICY "PDG and Admins manage workers v2" 
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

-- 2. Nettoyer toutes les anciennes politiques pour syndicate_alerts
DROP POLICY IF EXISTS "Admins can view all alerts" ON public.syndicate_alerts;
DROP POLICY IF EXISTS "PDG and Admins view all alerts" ON public.syndicate_alerts;
DROP POLICY IF EXISTS "PDG and Admins manage alerts" ON public.syndicate_alerts;

-- Recréer les politiques pour syndicate_alerts
CREATE POLICY "PDG and Admins view all alerts v2" 
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

CREATE POLICY "PDG and Admins manage alerts v2" 
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

-- 3. Nettoyer et recréer pour bureau_features
DROP POLICY IF EXISTS "Admins can manage features" ON public.bureau_features;
DROP POLICY IF EXISTS "PDG and Admins manage features" ON public.bureau_features;

CREATE POLICY "PDG and Admins manage features v2" 
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