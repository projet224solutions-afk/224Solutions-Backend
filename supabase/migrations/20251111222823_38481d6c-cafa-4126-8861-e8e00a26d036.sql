-- Sécuriser la table platform_settings avec RLS
-- Ce correctif empêche les utilisateurs authentifiés de lire les configurations système sensibles

-- Étape 1: Activer Row Level Security
ALTER TABLE public.platform_settings ENABLE ROW LEVEL SECURITY;

-- Étape 2: Supprimer toute politique permissive existante
DROP POLICY IF EXISTS "authenticated_read" ON public.platform_settings;
DROP POLICY IF EXISTS "public_read" ON public.platform_settings;

-- Étape 3: Service role a un accès complet (pour migrations et opérations système)
CREATE POLICY "service_role_all_access"
ON public.platform_settings
FOR ALL
USING (auth.role() = 'service_role')
WITH CHECK (auth.role() = 'service_role');

-- Étape 4: Les admins peuvent uniquement lire (pas modifier)
CREATE POLICY "admins_read_only"
ON public.platform_settings
FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid()
    AND role = 'admin'
  )
);

-- Étape 5: Créer une fonction sécurisée pour lire des paramètres publics spécifiques
CREATE OR REPLACE FUNCTION public.get_public_setting(setting_key text)
RETURNS text
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  -- Autoriser uniquement la lecture de paramètres non sensibles
  SELECT value 
  FROM public.platform_settings
  WHERE key = setting_key
    AND key IN ('app_name', 'support_email', 'maintenance_mode', 'version', 'app_version');
$$;

-- Accorder l'exécution à tous les utilisateurs authentifiés et anonymes
GRANT EXECUTE ON FUNCTION public.get_public_setting(text) TO authenticated, anon;

-- Commentaire de documentation
COMMENT ON TABLE public.platform_settings IS 'Table sécurisée - RLS activé. Service_role et admins uniquement. Utilisez get_public_setting() pour les paramètres publics.';
