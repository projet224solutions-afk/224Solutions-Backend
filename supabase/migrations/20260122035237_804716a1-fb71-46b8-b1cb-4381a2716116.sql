-- Ajouter les colonnes barcode_value et barcode_format à la table products
ALTER TABLE public.products 
ADD COLUMN IF NOT EXISTS barcode_value TEXT,
ADD COLUMN IF NOT EXISTS barcode_format TEXT DEFAULT 'CODE128';

-- Créer un index pour recherche rapide par code-barres
CREATE INDEX IF NOT EXISTS idx_products_barcode_value ON public.products(barcode_value) WHERE barcode_value IS NOT NULL;

-- Fonction pour générer un code-barres unique (EAN-13 compatible)
CREATE OR REPLACE FUNCTION public.generate_unique_barcode()
RETURNS TEXT AS $$
DECLARE
  new_barcode TEXT;
  barcode_exists BOOLEAN;
BEGIN
  LOOP
    -- Générer un code de 12 chiffres (préfixe vendeur + timestamp + random)
    new_barcode := LPAD(
      (EXTRACT(EPOCH FROM NOW())::BIGINT % 1000000000000)::TEXT,
      12,
      '0'
    );
    
    -- Ajouter le chiffre de contrôle EAN-13
    new_barcode := new_barcode || calculate_ean13_check_digit(new_barcode);
    
    -- Vérifier l'unicité
    SELECT EXISTS(SELECT 1 FROM products WHERE barcode_value = new_barcode) INTO barcode_exists;
    
    IF NOT barcode_exists THEN
      RETURN new_barcode;
    END IF;
  END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Fonction pour calculer le chiffre de contrôle EAN-13
CREATE OR REPLACE FUNCTION public.calculate_ean13_check_digit(code TEXT)
RETURNS TEXT AS $$
DECLARE
  sum_val INT := 0;
  i INT;
  digit INT;
  check_digit INT;
BEGIN
  FOR i IN 1..12 LOOP
    digit := SUBSTRING(code FROM i FOR 1)::INT;
    IF i % 2 = 0 THEN
      sum_val := sum_val + (digit * 3);
    ELSE
      sum_val := sum_val + digit;
    END IF;
  END LOOP;
  
  check_digit := (10 - (sum_val % 10)) % 10;
  RETURN check_digit::TEXT;
END;
$$ LANGUAGE plpgsql IMMUTABLE;