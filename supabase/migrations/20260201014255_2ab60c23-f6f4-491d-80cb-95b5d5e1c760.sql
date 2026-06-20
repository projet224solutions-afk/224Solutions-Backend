-- Ajouter la colonne full_name à la table orders si elle n'existe pas
DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_schema = 'public' 
    AND table_name = 'orders' 
    AND column_name = 'full_name'
  ) THEN
    ALTER TABLE public.orders ADD COLUMN full_name TEXT;
  END IF;
END $$;