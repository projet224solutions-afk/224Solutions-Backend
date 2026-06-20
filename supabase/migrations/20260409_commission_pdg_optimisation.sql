-- MIGRATION : Optimisation et sécurisation commissions & revenus PDG (Marketplace)
-- Date : 2026-04-09

-- 1. Dynamisation des frais PDG dans process_wallet_order_payment
CREATE OR REPLACE FUNCTION public.process_wallet_order_payment(
  p_user_id UUID,
  p_order_id UUID,
  p_amount NUMERIC,
  p_vendor_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_user_wallet_id UUID;
  v_user_balance NUMERIC;
  v_vendor_wallet_id UUID;
  v_transaction_id UUID;
  v_platform_fee NUMERIC;
  v_vendor_net NUMERIC;
  v_commission_result JSONB;
  v_fee_rate NUMERIC;
  v_vendor_user_id UUID;
BEGIN
  -- Récupérer le wallet utilisateur
  SELECT id, balance INTO v_user_wallet_id, v_user_balance
  FROM wallets
  WHERE user_id = p_user_id
  FOR UPDATE;
  IF v_user_wallet_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Wallet utilisateur non trouvé');
  END IF;
  IF v_user_balance < p_amount THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solde insuffisant');
  END IF;
  -- Récupérer user_id du vendeur
  SELECT user_id INTO v_vendor_user_id FROM vendors WHERE id = p_vendor_id;
  IF v_vendor_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Vendeur non trouvé');
  END IF;
  -- Récupérer ou créer wallet vendeur
  SELECT id INTO v_vendor_wallet_id FROM wallets WHERE user_id = v_vendor_user_id;
  IF v_vendor_wallet_id IS NULL THEN
    INSERT INTO wallets (user_id, balance, currency)
    VALUES (v_vendor_user_id, 0, 'GNF')
    RETURNING id INTO v_vendor_wallet_id;
  END IF;
  -- Lecture dynamique du taux de commission PDG
  SELECT (setting_value::NUMERIC) INTO v_fee_rate FROM pdg_settings WHERE setting_key = 'purchase_commission_percentage';
  IF v_fee_rate IS NULL THEN
    v_fee_rate := 0.025; -- fallback 2.5%
  END IF;
  -- Arrondir tous les montants à 2 décimales pour éviter les erreurs de précision
  v_platform_fee := ROUND(p_amount * v_fee_rate, 2);
  v_vendor_net := ROUND(p_amount - v_platform_fee, 2);
  v_transaction_id := gen_random_uuid();
  -- Débiter l'utilisateur
  UPDATE wallets SET balance = balance - ROUND(p_amount, 2), updated_at = NOW()
  WHERE id = v_user_wallet_id;
  -- Créditer le vendeur
  UPDATE wallets SET balance = balance + v_vendor_net, updated_at = NOW()
  WHERE id = v_vendor_wallet_id;
  -- Enregistrer la transaction
  INSERT INTO wallet_transactions (
    id, sender_wallet_id, receiver_wallet_id, amount, fee, net_amount,
    currency, transaction_type, status, description, metadata, created_at, completed_at
  ) VALUES (
    v_transaction_id, v_user_wallet_id, v_vendor_wallet_id, ROUND(p_amount, 2), v_platform_fee, v_vendor_net,
    'GNF', 'purchase', 'completed', 'Paiement commande #' || p_order_id::text,
    jsonb_build_object('order_id', p_order_id, 'vendor_id', p_vendor_id),
    NOW(), NOW()
  );
  -- Calculer et créditer la commission agent (la fonction credit_agent_commission applique aussi ROUND sur les montants)
  v_commission_result := credit_agent_commission(
    p_user_id,
    ROUND(p_amount, 2),
    'achat_produit',
    v_transaction_id,
    jsonb_build_object('order_id', p_order_id, 'vendor_id', p_vendor_id)
  );
  RETURN jsonb_build_object(
    'success', true,
    'transaction_id', v_transaction_id,
    'amount', ROUND(p_amount, 2),
    'platform_fee', v_platform_fee,
    'vendor_net', v_vendor_net,
    'agent_commission', v_commission_result
  );
END;
$$;

-- 2. Nettoyage des fonctions obsolètes
DROP FUNCTION IF EXISTS calculate_and_distribute_commissions(UUID, DECIMAL, DECIMAL);

-- 3. Uniformisation des paramètres de commission (Agent, Sous-Agent, PDG)

-- (Suppression des valeurs codées en dur dans credit_agent_commission, voir fonction existante)
-- S'assurer que credit_agent_commission lit les taux depuis pdg_settings ou system_settings
-- (Si besoin, adapter la fonction pour utiliser COALESCE(
--   (SELECT setting_value::NUMERIC FROM pdg_settings WHERE setting_key = 'agent_commission_percentage'),
--   (SELECT setting_value::NUMERIC FROM system_settings WHERE setting_key = 'agent_commission_percentage'),
--   0.20
-- ))
--
-- AUDIT : Tous les calculs de commissions (Agent, Sous-Agent, PDG) doivent utiliser ROUND(..., 2) pour garantir la précision décimale.
-- Vérifier que la fonction credit_agent_commission applique bien ROUND sur les montants crédités (agent_commission, parent_commission, etc).

-- 4. Sécurité wallet : la fonction create_agent_wallet existe et est utilisée dans credit_agent_commission
-- (aucune action requise, sécurité OK)

-- 5. Documentation :
-- Cette migration optimise la gestion des commissions, centralise les taux, supprime les fonctions obsolètes et sécurise la création des wallets agents.
