-- Ajouter la colonne currency à la table products
-- Permet aux vendeurs de spécifier la devise de leurs prix
-- Défaut GNF (Franc Guinéen) pour tous les produits existants

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS currency VARCHAR(3) DEFAULT 'GNF';

-- Mettre à jour les produits existants selon le pays du vendeur
UPDATE public.products p
SET currency = CASE v.country
  WHEN 'GN' THEN 'GNF'
  WHEN 'SN' THEN 'XOF'
  WHEN 'CI' THEN 'XOF'
  WHEN 'ML' THEN 'XOF'
  WHEN 'BF' THEN 'XOF'
  WHEN 'NE' THEN 'XOF'
  WHEN 'TG' THEN 'XOF'
  WHEN 'BJ' THEN 'XOF'
  WHEN 'CM' THEN 'XAF'
  WHEN 'CD' THEN 'CDF'
  WHEN 'NG' THEN 'NGN'
  WHEN 'GH' THEN 'GHS'
  WHEN 'MA' THEN 'MAD'
  WHEN 'FR' THEN 'EUR'
  WHEN 'DE' THEN 'EUR'
  WHEN 'BE' THEN 'EUR'
  WHEN 'US' THEN 'USD'
  WHEN 'GB' THEN 'GBP'
  ELSE 'GNF'
END
FROM public.vendors v
WHERE p.vendor_id = v.id
  AND v.country IS NOT NULL
  AND v.country <> ''
  AND p.currency IS NULL;

-- Index pour les requêtes filtrées par devise
CREATE INDEX IF NOT EXISTS idx_products_currency ON public.products(currency);
