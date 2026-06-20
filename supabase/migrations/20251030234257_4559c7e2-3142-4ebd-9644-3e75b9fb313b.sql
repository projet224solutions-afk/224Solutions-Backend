-- Mettre à jour la limite de produits du plan gratuit
UPDATE public.plans
SET max_products = 10
WHERE name = 'free';