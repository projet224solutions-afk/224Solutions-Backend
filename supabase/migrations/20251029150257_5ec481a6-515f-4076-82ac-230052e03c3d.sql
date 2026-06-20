-- Créer l'entrée customers manquante pour USR0001
-- Ce compte client existe dans profiles mais pas dans customers

INSERT INTO public.customers (user_id, addresses, payment_methods, preferences)
SELECT 
  p.id,
  '[]'::jsonb,
  '[]'::jsonb,
  '{}'::jsonb
FROM public.profiles p
WHERE p.custom_id = 'USR0001'
  AND NOT EXISTS (
    SELECT 1 FROM public.customers c WHERE c.user_id = p.id
  );

-- Vérifier et créer les entrées customers pour tous les clients qui n'en ont pas
INSERT INTO public.customers (user_id, addresses, payment_methods, preferences)
SELECT 
  p.id,
  '[]'::jsonb,
  '[]'::jsonb,
  '{}'::jsonb
FROM public.profiles p
WHERE p.role = 'client'
  AND NOT EXISTS (
    SELECT 1 FROM public.customers c WHERE c.user_id = p.id
  );