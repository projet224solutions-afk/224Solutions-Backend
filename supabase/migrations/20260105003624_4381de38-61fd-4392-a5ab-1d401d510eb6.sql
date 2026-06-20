-- Ajouter une policy de lecture publique sur service_types
-- Cette table contient des données de référence (types de services) qui doivent être lisibles par tous

-- Vérifier si RLS est activé et ajouter la policy
DO $$
BEGIN
  -- Activer RLS si ce n'est pas déjà fait
  IF NOT EXISTS (
    SELECT 1 FROM pg_tables 
    WHERE tablename = 'service_types' 
    AND rowsecurity = true
  ) THEN
    ALTER TABLE public.service_types ENABLE ROW LEVEL SECURITY;
  END IF;
END $$;

-- Supprimer l'ancienne policy si elle existe
DROP POLICY IF EXISTS "service_types_public_read" ON public.service_types;

-- Créer la policy de lecture publique
CREATE POLICY "service_types_public_read" 
ON public.service_types 
FOR SELECT 
USING (true);

-- Commentaire pour documentation
COMMENT ON POLICY "service_types_public_read" ON public.service_types IS 
'Permet à tous les utilisateurs de lire les types de services (données de référence)';