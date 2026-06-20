-- Corriger la table virtual_cards pour supporter les vrais numéros de carte
ALTER TABLE public.virtual_cards
DROP COLUMN IF EXISTS cardholder_name;

-- Le card_number doit être VARCHAR(19) pour supporter le format "4*** **** **** ****"
ALTER TABLE public.virtual_cards
ALTER COLUMN card_number TYPE VARCHAR(19);

-- Ajouter une colonne pour le nom du titulaire si elle n'existe pas
ALTER TABLE public.virtual_cards
ADD COLUMN IF NOT EXISTS holder_name VARCHAR(255);