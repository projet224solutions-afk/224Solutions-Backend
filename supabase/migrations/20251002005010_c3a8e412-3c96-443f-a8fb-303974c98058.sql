-- =====================================================
-- CORRECTION DES AVERTISSEMENTS DE SÉCURITÉ
-- Ajout de SET search_path aux fonctions manquantes
-- =====================================================

-- 1. Corriger generate_transaction_id
CREATE OR REPLACE FUNCTION public.generate_transaction_id()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  new_id TEXT;
BEGIN
  new_id := 'TXN' || TO_CHAR(NOW(), 'YYYYMMDD') || LPAD(FLOOR(RANDOM() * 1000000)::TEXT, 6, '0');
  
  WHILE EXISTS (SELECT 1 FROM public.wallet_transactions WHERE transaction_id = new_id) LOOP
    new_id := 'TXN' || TO_CHAR(NOW(), 'YYYYMMDD') || LPAD(FLOOR(RANDOM() * 1000000)::TEXT, 6, '0');
  END LOOP;
  
  RETURN new_id;
END;
$$;

-- 2. Corriger generate_custom_id
CREATE OR REPLACE FUNCTION public.generate_custom_id()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  letters TEXT := '';
  numbers TEXT := '';
  i INTEGER;
  new_custom_id TEXT;
BEGIN
  FOR i IN 1..3 LOOP
    letters := letters || CHR(65 + (RANDOM() * 25)::INTEGER);
  END LOOP;
  
  FOR i IN 1..4 LOOP
    numbers := numbers || (RANDOM() * 9)::INTEGER::TEXT;
  END LOOP;
  
  new_custom_id := letters || numbers;
  
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
$$;

-- 3. Corriger generate_card_number
CREATE OR REPLACE FUNCTION public.generate_card_number()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  new_card_number TEXT := '2245';
  i INTEGER;
BEGIN
  FOR i IN 1..12 LOOP
    new_card_number := new_card_number || (RANDOM() * 9)::INTEGER::TEXT;
  END LOOP;
  
  WHILE EXISTS (SELECT 1 FROM public.virtual_cards WHERE virtual_cards.card_number = new_card_number) LOOP
    new_card_number := '2245';
    FOR i IN 1..12 LOOP
      new_card_number := new_card_number || (RANDOM() * 9)::INTEGER::TEXT;
    END LOOP;
  END LOOP;
  
  RETURN new_card_number;
END;
$$;

-- 4. Corriger generate_order_number (trigger function)
CREATE OR REPLACE FUNCTION public.generate_order_number()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  NEW.order_number = 'ORD-' || EXTRACT(YEAR FROM NOW()) || '-' || 
                     LPAD(nextval('order_number_seq')::text, 6, '0');
  RETURN NEW;
END;
$$;

-- 5. Corriger handle_new_user_complete
CREATE OR REPLACE FUNCTION public.handle_new_user_complete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  card_number TEXT;
  custom_id TEXT;
BEGIN
  INSERT INTO public.profiles (id, email, first_name, last_name, role)
  VALUES (
    NEW.id,
    NEW.email,
    NEW.raw_user_meta_data ->> 'first_name',
    NEW.raw_user_meta_data ->> 'last_name',
    COALESCE((NEW.raw_user_meta_data ->> 'role')::user_role, 'client')
  )
  ON CONFLICT (id) DO NOTHING;
  
  INSERT INTO public.user_ids (user_id, custom_id)
  VALUES (NEW.id, generate_custom_id())
  ON CONFLICT (user_id) DO NOTHING;
  
  INSERT INTO public.wallets (user_id, balance, currency)
  VALUES (NEW.id, 10000, 'GNF')
  ON CONFLICT (user_id, currency) DO NOTHING;
  
  SELECT ui.custom_id INTO custom_id
  FROM public.user_ids ui
  WHERE ui.user_id = NEW.id;
  
  card_number := '2245' || LPAD((RANDOM() * 999999999999)::BIGINT::TEXT, 12, '0');
  
  INSERT INTO public.virtual_cards (
    user_id,
    card_number,
    cardholder_name,
    expiry_date,
    cvv,
    daily_limit,
    monthly_limit
  )
  VALUES (
    NEW.id,
    card_number,
    COALESCE(NEW.raw_user_meta_data ->> 'first_name', 'Client') || ' ' || COALESCE(NEW.raw_user_meta_data ->> 'last_name', custom_id),
    (NOW() + INTERVAL '3 years')::TIMESTAMP,
    LPAD((RANDOM() * 900 + 100)::INTEGER::TEXT, 3, '0'),
    500000,
    2000000
  )
  ON CONFLICT (user_id) DO NOTHING;
  
  RETURN NEW;
END;
$$;