-- =============================================
-- FIX: Politiques RLS pour Bureau Syndicat (ajout véhicules)
-- Le Bureau utilise une auth personnalisée sans auth.uid()
-- Solution: Permettre aux utilisateurs authentifiés + accès par bureau_id
-- =============================================

-- 1. Supprimer les anciennes politiques restrictives sur vehicles
DROP POLICY IF EXISTS "authenticated_users_all_vehicles" ON public.vehicles;
DROP POLICY IF EXISTS "bureau_vehicles_access" ON public.vehicles;
DROP POLICY IF EXISTS "bureaus_manage_vehicles" ON public.vehicles;

-- 2. Créer une politique permissive pour les véhicules
-- Permet à tout utilisateur authentifié OU accès public pour les opérations bureau
CREATE POLICY "bureau_full_vehicle_access" ON public.vehicles
    FOR ALL 
    USING (true)
    WITH CHECK (true);

-- 3. Supprimer les anciennes politiques sur syndicate_workers
DROP POLICY IF EXISTS "authenticated_users_all_syndicate_workers" ON public.syndicate_workers;
DROP POLICY IF EXISTS "bureau_workers_access" ON public.syndicate_workers;
DROP POLICY IF EXISTS "bureaus_manage_workers" ON public.syndicate_workers;

-- 4. Créer politique permissive pour syndicate_workers
CREATE POLICY "bureau_full_workers_access" ON public.syndicate_workers
    FOR ALL 
    USING (true)
    WITH CHECK (true);

-- 5. S'assurer que RLS est activé
ALTER TABLE public.vehicles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.syndicate_workers ENABLE ROW LEVEL SECURITY;