-- =====================================================
-- CORRECTION COMPLÈTE DES FONCTIONS SANS search_path
-- =====================================================

-- 1. Corriger update_updated_at_column
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path = public;

-- 2. Corriger generate_unique_id
CREATE OR REPLACE FUNCTION public.generate_unique_id(prefix text)
RETURNS text AS $$
DECLARE
  new_id text;
  counter integer;
BEGIN
  SELECT COALESCE(MAX(current_value), 0) + 1 INTO counter
  FROM public.id_counters WHERE table_prefix = prefix;
  
  INSERT INTO public.id_counters (table_prefix, current_value)
  VALUES (prefix, counter)
  ON CONFLICT (table_prefix) 
  DO UPDATE SET current_value = counter, updated_at = now();
  
  new_id := prefix || '-' || LPAD(counter::text, 6, '0');
  RETURN new_id;
END;
$$ LANGUAGE plpgsql SET search_path = public;

-- 3. Corriger create_agent_wallet (version trigger)
DROP FUNCTION IF EXISTS public.create_agent_wallet() CASCADE;
CREATE OR REPLACE FUNCTION public.create_agent_wallet()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO public.agent_wallets (agent_id, balance, currency, wallet_status)
  VALUES (NEW.id, 0, 'GNF', 'active')
  ON CONFLICT (agent_id) DO NOTHING;
  RETURN NEW;
END;
$$;

-- 4. Corriger create_agent_wallet (version function avec param)
DROP FUNCTION IF EXISTS public.create_agent_wallet(UUID) CASCADE;
CREATE OR REPLACE FUNCTION public.create_agent_wallet(p_agent_id UUID)
RETURNS TABLE(id uuid, agent_id uuid, balance numeric, currency text, wallet_status text, created_at timestamp with time zone, updated_at timestamp with time zone)
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
  v_wallet_id UUID;
BEGIN
  -- Vérifier si le wallet existe déjà
  IF EXISTS (SELECT 1 FROM public.agent_wallets aw WHERE aw.agent_id = p_agent_id) THEN
    RETURN QUERY SELECT aw.id, aw.agent_id, aw.balance, aw.currency, aw.wallet_status, aw.created_at, aw.updated_at 
    FROM public.agent_wallets aw WHERE aw.agent_id = p_agent_id;
    RETURN;
  END IF;
  
  -- Créer le wallet
  RETURN QUERY INSERT INTO public.agent_wallets (agent_id, balance, currency, wallet_status)
  VALUES (p_agent_id, 0, 'GNF', 'active')
  RETURNING agent_wallets.id, agent_wallets.agent_id, agent_wallets.balance, agent_wallets.currency, agent_wallets.wallet_status, agent_wallets.created_at, agent_wallets.updated_at;
END;
$$;