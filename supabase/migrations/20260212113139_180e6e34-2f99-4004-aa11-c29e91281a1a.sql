-- Corriger le pays du vendeur Bella Business (Pikine est au Sénégal, pas en Guinée)
UPDATE public.vendors 
SET country = 'Sénégal' 
WHERE id = '2e0c1abf-f1cb-420b-a1b5-13507019f4df' 
AND city = 'Pikine';