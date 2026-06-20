-- Corriger la fonction generate_custom_id pour éviter l'ambiguïté
CREATE OR REPLACE FUNCTION public.generate_custom_id()
RETURNS text
LANGUAGE plpgsql
AS $function$
DECLARE
  letters TEXT := '';
  numbers TEXT := '';
  i INTEGER;
  new_custom_id TEXT;
BEGIN
  -- Générer 3 lettres aléatoires
  FOR i IN 1..3 LOOP
    letters := letters || CHR(65 + (RANDOM() * 25)::INTEGER);
  END LOOP;
  
  -- Générer 4 chiffres aléatoires
  FOR i IN 1..4 LOOP
    numbers := numbers || (RANDOM() * 9)::INTEGER::TEXT;
  END LOOP;
  
  new_custom_id := letters || numbers;
  
  -- Vérifier l'unicité
  WHILE EXISTS (SELECT 1 FROM public.user_ids WHERE user_ids.custom_id = new_custom_id) LOOP
    letters := '';
    numbers := '';
    FOR i IN 1..3 LOOP
      letters := letters || CHR(65 + (RANDOM() * 25)::INTEGER);
    END LOOP;
    FOR i IN 1..4 LOOP
      numbers := numbers || (RANDOM() * 9)::INTEGER::TEXT;
    END LOOP;
    new_custom_id := letters || numbers;
  END LOOP;
  
  RETURN new_custom_id;
END;
$function$;

-- Créer automatiquement un wallet et un ID pour tous les utilisateurs existants qui n'en ont pas
INSERT INTO public.wallets (user_id, balance, currency)
SELECT id, 0, 'GNF' 
FROM auth.users 
WHERE id NOT IN (SELECT user_id FROM public.wallets);

-- Créer automatiquement un ID unique pour tous les utilisateurs existants qui n'en ont pas
INSERT INTO public.user_ids (user_id, custom_id)
SELECT id, generate_custom_id()
FROM auth.users 
WHERE id NOT IN (SELECT user_id FROM public.user_ids);