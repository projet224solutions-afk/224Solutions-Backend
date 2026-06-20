
-- Ajouter les colonnes manquantes pour documents et photos
ALTER TABLE public.registered_motos 
ADD COLUMN IF NOT EXISTS documents jsonb DEFAULT '[]'::jsonb,
ADD COLUMN IF NOT EXISTS photos jsonb DEFAULT '[]'::jsonb;

-- Créer une politique simple pour les admins qui peuvent tout faire
DROP POLICY IF EXISTS "Admins have full access to registered_motos" ON public.registered_motos;

CREATE POLICY "Admins have full access to registered_motos"
ON public.registered_motos
FOR ALL
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'
  )
);

-- Politique pour les membres du bureau (create)
DROP POLICY IF EXISTS "Bureau members can create motos" ON public.registered_motos;

CREATE POLICY "Bureau members can create motos"
ON public.registered_motos
FOR INSERT
TO authenticated
WITH CHECK (
  -- Permettre à tout utilisateur authentifié d'insérer si bureau_id est fourni
  bureau_id IS NOT NULL
);

-- Politique pour voir ses propres motos
DROP POLICY IF EXISTS "Users can view motos they created" ON public.registered_motos;

CREATE POLICY "Users can view motos they created"
ON public.registered_motos
FOR SELECT
TO authenticated
USING (
  worker_id = auth.uid() OR
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role IN ('admin', 'syndicat')
  )
);

COMMENT ON COLUMN public.registered_motos.documents IS 'Array of document URLs in JSON format';
COMMENT ON COLUMN public.registered_motos.photos IS 'Array of photo URLs in JSON format';
