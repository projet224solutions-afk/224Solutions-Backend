-- Migrer les codes-barres existants de 'barcode' vers 'barcode_value'
UPDATE public.products 
SET barcode_value = barcode 
WHERE barcode IS NOT NULL 
  AND barcode != '' 
  AND (barcode_value IS NULL OR barcode_value = '');

-- Créer un index pour optimiser la recherche POS
CREATE INDEX IF NOT EXISTS idx_products_barcode_search 
ON public.products(barcode_value) 
WHERE barcode_value IS NOT NULL;