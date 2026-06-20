-- Créer la politique PDG uniquement si elle n'existe pas
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies 
    WHERE tablename = 'platform_revenue' 
    AND policyname = 'PDG can view all platform revenue'
  ) THEN
    CREATE POLICY "PDG can view all platform revenue"
    ON platform_revenue
    FOR SELECT
    USING (
      EXISTS (
        SELECT 1 FROM profiles
        WHERE profiles.id = auth.uid()
        AND profiles.role = 'admin'
      )
    );
  END IF;
END $$;