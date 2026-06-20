
-- ============================================
-- CORRECTION RLS POLICIES TABLE VEHICLES
-- Permettre aux bureaux d'ajouter/gérer leurs véhicules
-- ============================================

-- 1. Activer RLS sur vehicles si pas déjà fait
ALTER TABLE public.vehicles ENABLE ROW LEVEL SECURITY;

-- 2. Supprimer les anciennes policies si elles existent
DROP POLICY IF EXISTS "Bureaus can manage their vehicles" ON public.vehicles;
DROP POLICY IF EXISTS "Admins can manage all vehicles" ON public.vehicles;
DROP POLICY IF EXISTS "PDG can manage all vehicles" ON public.vehicles;
DROP POLICY IF EXISTS "Service role full access vehicles" ON public.vehicles;
DROP POLICY IF EXISTS "Anyone with bureau token can view vehicles" ON public.vehicles;
DROP POLICY IF EXISTS "Bureaus can insert their vehicles" ON public.vehicles;

-- 3. Policy pour les bureaux : gestion complète de leurs véhicules
CREATE POLICY "Bureaus can manage their vehicles"
ON public.vehicles
FOR ALL
USING (
  EXISTS (
    SELECT 1 FROM public.bureaus
    WHERE bureaus.id = vehicles.bureau_id
    AND bureaus.access_token IS NOT NULL
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.bureaus
    WHERE bureaus.id = vehicles.bureau_id
    AND bureaus.access_token IS NOT NULL
  )
);

-- 4. Policy pour les admins : accès total
CREATE POLICY "Admins can manage all vehicles"
ON public.vehicles
FOR ALL
USING (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'
  )
);

-- 5. Policy pour le PDG : accès total
CREATE POLICY "PDG can manage all vehicles"
ON public.vehicles
FOR ALL
USING (
  EXISTS (
    SELECT 1 FROM public.pdg_management
    WHERE pdg_management.user_id = auth.uid()
  )
);

-- 6. Policy pour le service role
CREATE POLICY "Service role full access vehicles"
ON public.vehicles
FOR ALL
USING (auth.role() = 'service_role')
WITH CHECK (auth.role() = 'service_role');

-- 7. Policy publique pour consulter les véhicules via token bureau
CREATE POLICY "Anyone with bureau token can view vehicles"
ON public.vehicles
FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM public.bureaus
    WHERE bureaus.id = vehicles.bureau_id
    AND bureaus.access_token IS NOT NULL
  )
);
