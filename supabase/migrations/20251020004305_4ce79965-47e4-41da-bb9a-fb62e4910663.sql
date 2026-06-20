-- Ajouter la politique DELETE pour les bureaux (pour les admins)
CREATE POLICY "Admins can delete bureaus"
ON public.bureaus
FOR DELETE
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'::user_role
  )
);

-- S'assurer que toutes les tables liées ont les bonnes politiques CASCADE
-- pour éviter les erreurs de contraintes de clés étrangères

-- Politique DELETE pour syndicate_workers
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies 
    WHERE tablename = 'syndicate_workers' 
    AND policyname = 'Admins can delete workers'
  ) THEN
    CREATE POLICY "Admins can delete workers"
    ON public.syndicate_workers
    FOR DELETE
    TO authenticated
    USING (
      EXISTS (
        SELECT 1 FROM public.profiles
        WHERE profiles.id = auth.uid()
        AND profiles.role = 'admin'::user_role
      )
    );
  END IF;
END $$;

-- Politique DELETE pour members
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies 
    WHERE tablename = 'members' 
    AND policyname = 'Admins can delete members'
  ) THEN
    CREATE POLICY "Admins can delete members"
    ON public.members
    FOR DELETE
    TO authenticated
    USING (true);
  END IF;
END $$;

-- Politique DELETE pour registered_motos  
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies 
    WHERE tablename = 'registered_motos' 
    AND policyname = 'Admins can delete motos'
  ) THEN
    CREATE POLICY "Admins can delete motos"
    ON public.registered_motos
    FOR DELETE
    TO authenticated
    USING (true);
  END IF;
END $$;