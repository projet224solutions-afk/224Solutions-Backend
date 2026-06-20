
-- =====================================================
-- CORRECTION SÉCURITÉ: Ajout de search_path aux fonctions
-- Suppression puis recréation avec search_path
-- =====================================================

-- Supprimer les fonctions existantes
DROP FUNCTION IF EXISTS public.initialize_user_wallet(UUID) CASCADE;
DROP FUNCTION IF EXISTS public.process_wallet_transfer_with_fees(UUID, UUID, DECIMAL, TEXT) CASCADE;
DROP FUNCTION IF EXISTS public.auto_create_user_wallet() CASCADE;
DROP FUNCTION IF EXISTS public.generate_vendor_agent_code() CASCADE;
DROP FUNCTION IF EXISTS public.generate_vendor_agent_access_token() CASCADE;
DROP FUNCTION IF EXISTS public.set_vendor_agent_defaults() CASCADE;
DROP FUNCTION IF EXISTS public.update_vendor_agents_updated_at() CASCADE;

-- 1. Fonction de création automatique de wallet
CREATE FUNCTION public.auto_create_user_wallet()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.wallets (user_id, balance, wallet_status, currency)
  VALUES (NEW.id, 0, 'active', 'GNF')
  ON CONFLICT (user_id) DO NOTHING;
  RETURN NEW;
END;
$$;

-- 2. Fonction de traitement des transferts wallet avec frais
CREATE FUNCTION public.process_wallet_transfer_with_fees(
  p_sender_id UUID,
  p_receiver_id UUID,
  p_amount DECIMAL,
  p_description TEXT DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_fee_percent DECIMAL := 0.025;
  v_fee_amount DECIMAL;
  v_final_amount DECIMAL;
  v_sender_balance DECIMAL;
  v_transaction_id UUID;
  v_result JSON;
BEGIN
  v_fee_amount := p_amount * v_fee_percent;
  v_final_amount := p_amount - v_fee_amount;

  SELECT balance INTO v_sender_balance
  FROM public.wallets
  WHERE user_id = p_sender_id
  FOR UPDATE;

  IF v_sender_balance < p_amount THEN
    RAISE EXCEPTION 'Solde insuffisant';
  END IF;

  UPDATE public.wallets
  SET balance = balance - p_amount, updated_at = NOW()
  WHERE user_id = p_sender_id;

  UPDATE public.wallets
  SET balance = balance + v_final_amount, updated_at = NOW()
  WHERE user_id = p_receiver_id;

  INSERT INTO public.wallet_transactions (
    user_id, amount, transaction_type, status, description, created_at
  ) VALUES (
    p_sender_id, -p_amount, 'transfer_out', 'completed',
    COALESCE(p_description, 'Transfert vers un autre utilisateur'), NOW()
  ) RETURNING id INTO v_transaction_id;

  INSERT INTO public.wallet_transactions (
    user_id, amount, transaction_type, status, description, created_at
  ) VALUES (
    p_receiver_id, v_final_amount, 'transfer_in', 'completed',
    COALESCE(p_description, 'Transfert reçu'), NOW()
  );

  v_result := json_build_object(
    'success', true,
    'transaction_id', v_transaction_id,
    'amount_sent', p_amount,
    'fee_amount', v_fee_amount,
    'amount_received', v_final_amount
  );

  RETURN v_result;
END;
$$;

-- 3. Fonction d'initialisation de wallet utilisateur
CREATE FUNCTION public.initialize_user_wallet(p_user_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_wallet_id UUID;
  v_result JSON;
BEGIN
  INSERT INTO public.wallets (user_id, balance, wallet_status, currency)
  VALUES (p_user_id, 0, 'active', 'GNF')
  ON CONFLICT (user_id) 
  DO UPDATE SET updated_at = NOW()
  RETURNING id INTO v_wallet_id;

  SELECT json_build_object(
    'id', w.id,
    'user_id', w.user_id,
    'balance', w.balance,
    'wallet_status', w.wallet_status,
    'currency', w.currency,
    'created_at', w.created_at
  ) INTO v_result
  FROM public.wallets w
  WHERE w.id = v_wallet_id;

  RETURN v_result;
END;
$$;

-- 4. Fonction de génération de code agent vendeur
CREATE FUNCTION public.generate_vendor_agent_code()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code TEXT;
  v_exists BOOLEAN;
BEGIN
  LOOP
    v_code := 'AGT-' || LPAD(FLOOR(RANDOM() * 10000)::TEXT, 4, '0');
    SELECT EXISTS(SELECT 1 FROM public.vendor_agents WHERE agent_code = v_code) INTO v_exists;
    EXIT WHEN NOT v_exists;
  END LOOP;
  RETURN v_code;
END;
$$;

-- 5. Fonction de génération de jeton d'accès agent vendeur
CREATE FUNCTION public.generate_vendor_agent_access_token()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  RETURN encode(extensions.gen_random_bytes(32), 'hex');
END;
$$;

-- 6. Fonction pour définir les valeurs par défaut des agents vendeur
CREATE FUNCTION public.set_vendor_agent_defaults()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.agent_code IS NULL THEN
    NEW.agent_code := public.generate_vendor_agent_code();
  END IF;
  
  IF NEW.access_token IS NULL THEN
    NEW.access_token := public.generate_vendor_agent_access_token();
  END IF;
  
  IF NEW.permissions IS NULL THEN
    NEW.permissions := ARRAY[]::TEXT[];
  END IF;
  
  RETURN NEW;
END;
$$;

-- 7. Fonction de mise à jour du timestamp des agents vendeur
CREATE FUNCTION public.update_vendor_agents_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

-- Recréer les triggers si nécessaires
DROP TRIGGER IF EXISTS set_vendor_agent_defaults_trigger ON public.vendor_agents;
CREATE TRIGGER set_vendor_agent_defaults_trigger
  BEFORE INSERT ON public.vendor_agents
  FOR EACH ROW
  EXECUTE FUNCTION public.set_vendor_agent_defaults();

DROP TRIGGER IF EXISTS update_vendor_agents_updated_at_trigger ON public.vendor_agents;
CREATE TRIGGER update_vendor_agents_updated_at_trigger
  BEFORE UPDATE ON public.vendor_agents
  FOR EACH ROW
  EXECUTE FUNCTION public.update_vendor_agents_updated_at();
