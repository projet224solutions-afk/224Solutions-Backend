-- CORRECTION CRITIQUE #1: RLS Policy pour taxi_trips
-- Permet à TOUS les conducteurs authentifiés de voir les courses 'requested'
-- sans vérifier is_online (filtrage côté client)

-- Supprimer l'ancienne policy restrictive
DROP POLICY IF EXISTS "Drivers can view available rides" ON public.taxi_trips;
DROP POLICY IF EXISTS "All drivers can view requested rides" ON public.taxi_trips;
DROP POLICY IF EXISTS "All authenticated drivers can view requested rides" ON public.taxi_trips;

-- Créer nouvelle policy permissive
CREATE POLICY "All authenticated drivers can view requested rides"
ON public.taxi_trips
FOR SELECT
TO authenticated
USING (
  status = 'requested' 
  AND driver_id IS NULL
  AND EXISTS (
    SELECT 1 FROM taxi_drivers 
    WHERE taxi_drivers.user_id = auth.uid()
    -- ✅ Pas de vérification is_online ici
    -- Le filtrage se fera côté client dans le code
  )
);

-- Commentaire explicatif
COMMENT ON POLICY "All authenticated drivers can view requested rides" ON public.taxi_trips IS 
'Permet à tous les conducteurs authentifiés de voir les courses disponibles (requested, driver_id=NULL) pour que Realtime puisse envoyer les événements. Le filtrage is_online se fait côté client.';

-- CORRECTION CRITIQUE #2: S'assurer que Realtime est activé
-- Activer REPLICA IDENTITY FULL
ALTER TABLE taxi_trips REPLICA IDENTITY FULL;

-- Ajouter à la publication Realtime si pas déjà fait
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables 
        WHERE pubname = 'supabase_realtime' 
        AND tablename = 'taxi_trips'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE taxi_trips;
        RAISE NOTICE 'Table taxi_trips ajoutée à supabase_realtime';
    ELSE
        RAISE NOTICE 'Table taxi_trips déjà dans supabase_realtime';
    END IF;
END $$;

-- Vérification finale
DO $$
DECLARE
    realtime_enabled BOOLEAN;
    policy_count INTEGER;
BEGIN
    -- Vérifier Realtime
    SELECT EXISTS (
        SELECT 1 FROM pg_publication_tables 
        WHERE pubname = 'supabase_realtime' 
        AND tablename = 'taxi_trips'
    ) INTO realtime_enabled;
    
    -- Vérifier policies
    SELECT COUNT(*) INTO policy_count
    FROM pg_policies 
    WHERE tablename = 'taxi_trips' 
    AND policyname LIKE '%drivers%view%';
    
    -- Afficher résumé
    RAISE NOTICE '========================================';
    RAISE NOTICE 'VÉRIFICATION TAXI_TRIPS';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Realtime activé: %', realtime_enabled;
    RAISE NOTICE 'Policies conducteurs: %', policy_count;
    RAISE NOTICE '========================================';
    
    IF NOT realtime_enabled THEN
        RAISE WARNING 'Realtime NOT activé pour taxi_trips!';
    END IF;
    
    IF policy_count = 0 THEN
        RAISE WARNING 'Aucune policy pour les conducteurs!';
    END IF;
END $$;
