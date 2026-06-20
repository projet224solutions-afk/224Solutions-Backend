-- Ajouter les colonnes manquantes à la table vehicles
ALTER TABLE public.vehicles 
ADD COLUMN IF NOT EXISTS license_plate VARCHAR(20),
ADD COLUMN IF NOT EXISTS digital_badge_id VARCHAR(50),
ADD COLUMN IF NOT EXISTS qr_code_data TEXT,
ADD COLUMN IF NOT EXISTS badge_generated_at TIMESTAMPTZ DEFAULT NOW(),
ADD COLUMN IF NOT EXISTS verified BOOLEAN DEFAULT false,
ADD COLUMN IF NOT EXISTS verified_by UUID REFERENCES auth.users(id),
ADD COLUMN IF NOT EXISTS verified_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS color VARCHAR(30);

-- Créer des index pour les performances
CREATE INDEX IF NOT EXISTS idx_vehicles_bureau_id ON public.vehicles(bureau_id);
CREATE INDEX IF NOT EXISTS idx_vehicles_owner_member_id ON public.vehicles(owner_member_id);
CREATE INDEX IF NOT EXISTS idx_vehicles_serial_number ON public.vehicles(serial_number);
CREATE INDEX IF NOT EXISTS idx_vehicles_digital_badge_id ON public.vehicles(digital_badge_id);

-- Activer RLS si ce n'est pas déjà fait
ALTER TABLE public.vehicles ENABLE ROW LEVEL SECURITY;

-- Supprimer toutes les anciennes politiques
DO $$ 
BEGIN
    DROP POLICY IF EXISTS "pdg_admin_full_access_vehicles" ON public.vehicles;
    DROP POLICY IF EXISTS "president_manage_bureau_vehicles" ON public.vehicles;
    DROP POLICY IF EXISTS "members_view_bureau_vehicles" ON public.vehicles;
    DROP POLICY IF EXISTS "president_insert_vehicles" ON public.vehicles;
    DROP POLICY IF EXISTS "Enable read access for all authenticated users" ON public.vehicles;
    DROP POLICY IF EXISTS "Enable insert for authenticated users only" ON public.vehicles;
    DROP POLICY IF EXISTS "workers_view_bureau_vehicles" ON public.vehicles;
    DROP POLICY IF EXISTS "authorized_insert_vehicles" ON public.vehicles;
    DROP POLICY IF EXISTS "authenticated_users_insert_vehicles" ON public.vehicles;
EXCEPTION WHEN OTHERS THEN
    NULL;
END $$;

-- Politique très permissive pour tous les utilisateurs authentifiés
CREATE POLICY "authenticated_users_all_vehicles" ON public.vehicles
    FOR ALL 
    USING (auth.uid() IS NOT NULL)
    WITH CHECK (auth.uid() IS NOT NULL);