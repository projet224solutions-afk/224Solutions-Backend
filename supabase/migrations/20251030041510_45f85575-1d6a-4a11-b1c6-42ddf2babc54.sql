-- Ajouter une colonne vendor_code à la table vendors avec format standardisé VND####
ALTER TABLE vendors ADD COLUMN IF NOT EXISTS vendor_code TEXT UNIQUE;

-- Fonction pour générer le prochain code vendeur
CREATE OR REPLACE FUNCTION generate_vendor_code()
RETURNS TEXT AS $$
DECLARE
  next_num INTEGER;
  new_code TEXT;
BEGIN
  -- Trouver le prochain numéro disponible
  SELECT COALESCE(MAX(CAST(SUBSTRING(vendor_code FROM 4) AS INTEGER)), 0) + 1
  INTO next_num
  FROM vendors
  WHERE vendor_code ~ '^VND[0-9]{4}$';
  
  -- Générer le code avec padding
  new_code := 'VND' || LPAD(next_num::TEXT, 4, '0');
  
  RETURN new_code;
END;
$$ LANGUAGE plpgsql;

-- Trigger pour générer automatiquement le vendor_code lors de l'insertion
CREATE OR REPLACE FUNCTION set_vendor_code()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.vendor_code IS NULL THEN
    NEW.vendor_code := generate_vendor_code();
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_set_vendor_code ON vendors;
CREATE TRIGGER trigger_set_vendor_code
  BEFORE INSERT ON vendors
  FOR EACH ROW
  EXECUTE FUNCTION set_vendor_code();

-- Migrer les données existantes : attribuer des codes aux vendeurs existants
DO $$
DECLARE
  vendor_record RECORD;
  counter INTEGER := 0;
BEGIN
  FOR vendor_record IN 
    SELECT id FROM vendors WHERE vendor_code IS NULL ORDER BY created_at
  LOOP
    counter := counter + 1;
    UPDATE vendors 
    SET vendor_code = 'VND' || LPAD(counter::TEXT, 4, '0')
    WHERE id = vendor_record.id;
  END LOOP;
END $$;

-- Mettre à jour les custom_id des profiles pour qu'ils correspondent aux vendor_code
UPDATE profiles p
SET custom_id = v.vendor_code
FROM vendors v
WHERE v.user_id = p.id 
  AND p.role = 'vendeur'
  AND v.vendor_code IS NOT NULL;

-- Créer un index sur vendor_code pour les recherches rapides
CREATE INDEX IF NOT EXISTS idx_vendors_vendor_code ON vendors(vendor_code);