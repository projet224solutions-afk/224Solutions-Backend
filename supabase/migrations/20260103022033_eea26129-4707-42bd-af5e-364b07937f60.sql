-- Ajouter une politique pour permettre aux utilisateurs anonymes de voir les produits numériques disponibles
CREATE POLICY "Anyone can view available products on marketplace" 
ON public.service_products 
FOR SELECT 
USING (is_available = true);

-- Aussi ajouter une politique pour professional_services si nécessaire
-- Vérifier d'abord les politiques existantes et ajouter si manquant
DO $$
BEGIN
  -- Ajouter politique SELECT pour anon sur professional_services si elle n'existe pas
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies 
    WHERE tablename = 'professional_services' 
    AND policyname = 'Anyone can view services on marketplace'
  ) THEN
    CREATE POLICY "Anyone can view services on marketplace" 
    ON public.professional_services 
    FOR SELECT 
    USING (status IN ('active', 'pending'));
  END IF;
END $$;