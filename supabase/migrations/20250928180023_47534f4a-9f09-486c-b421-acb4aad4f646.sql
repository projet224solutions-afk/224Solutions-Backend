-- Corriger la fonction generate_card_number pour éviter l'ambiguïté
CREATE OR REPLACE FUNCTION public.generate_card_number()
RETURNS text
LANGUAGE plpgsql
AS $function$
DECLARE
  new_card_number TEXT := '2245'; -- Préfixe 224SOLUTIONS
  i INTEGER;
BEGIN
  -- Générer 12 chiffres supplémentaires
  FOR i IN 1..12 LOOP
    new_card_number := new_card_number || (RANDOM() * 9)::INTEGER::TEXT;
  END LOOP;
  
  -- Vérifier l'unicité
  WHILE EXISTS (SELECT 1 FROM public.virtual_cards WHERE virtual_cards.card_number = new_card_number) LOOP
    new_card_number := '2245';
    FOR i IN 1..12 LOOP
      new_card_number := new_card_number || (RANDOM() * 9)::INTEGER::TEXT;
    END LOOP;
  END LOOP;
  
  RETURN new_card_number;
END;
$function$;

-- Créer une carte virtuelle pour tous les utilisateurs existants qui n'en ont pas
INSERT INTO public.virtual_cards (user_id, card_number, expiry_date, cvv, status)
SELECT 
  id, 
  generate_card_number(),
  TO_CHAR(NOW() + INTERVAL '5 years', 'MM/YY'),
  LPAD((RANDOM() * 999)::INT::TEXT, 3, '0'),
  'active'
FROM auth.users 
WHERE id NOT IN (SELECT user_id FROM public.virtual_cards);