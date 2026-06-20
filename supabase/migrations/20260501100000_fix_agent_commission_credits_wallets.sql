-- ============================================================
-- FIX CRITIQUE: credit_agent_wallet_gnf doit créditer wallets
-- ============================================================
-- PROBLÈME: La fonction credit_agent_wallet_gnf écrivait uniquement
-- dans agent_wallets (table miroir). Mais toute l'interface agent lit
-- le solde depuis wallets (source de vérité). Résultat: les commissions
-- étaient invisibles pour l'agent.
--
-- FIX: On crédite maintenant les deux tables:
--   1. agent_wallets  → pour les stats/historique commission (inchangé)
--   2. wallets        → source de vérité lue par l'interface agent

CREATE OR REPLACE FUNCTION public.credit_agent_wallet_gnf(
  p_agent_id uuid,
  p_amount numeric
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  IF p_agent_id IS NULL OR COALESCE(p_amount, 0) <= 0 THEN
    RETURN;
  END IF;

  -- 1. Créditer agent_wallets (historique/stats — toujours maintenu)
  INSERT INTO public.agent_wallets (
    agent_id,
    balance,
    currency,
    wallet_status,
    currency_type,
    updated_at
  ) VALUES (
    p_agent_id,
    ROUND(p_amount, 2),
    'GNF',
    'active',
    'GNF',
    NOW()
  )
  ON CONFLICT (agent_id, currency_type)
  DO UPDATE SET
    balance      = COALESCE(public.agent_wallets.balance, 0) + EXCLUDED.balance,
    currency     = 'GNF',
    wallet_status = COALESCE(public.agent_wallets.wallet_status, 'active'),
    updated_at   = NOW();

  -- 2. Récupérer le user_id de l'agent dans agents_management
  SELECT user_id INTO v_user_id
  FROM public.agents_management
  WHERE id = p_agent_id
  LIMIT 1;

  -- 3. Créditer wallets (SOURCE DE VÉRITÉ lue par l'interface)
  IF v_user_id IS NOT NULL THEN
    INSERT INTO public.wallets (user_id, balance, currency, created_at, updated_at)
    VALUES (v_user_id, ROUND(p_amount, 2), 'GNF', NOW(), NOW())
    ON CONFLICT (user_id)
    DO UPDATE SET
      balance    = COALESCE(public.wallets.balance, 0) + EXCLUDED.balance,
      updated_at = NOW();
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.credit_agent_wallet_gnf(uuid, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.credit_agent_wallet_gnf(uuid, numeric) TO service_role;

-- ============================================================
-- SYNC: Resynchroniser les soldes existants agent_wallets → wallets
-- ============================================================
-- Pour les agents qui ont déjà des commissions dans agent_wallets
-- mais dont le solde wallets ne reflète pas ces commissions.
-- On additionne les soldes (ne pas écraser si wallets a déjà de l'argent).
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT am.user_id, COALESCE(aw.balance, 0) AS agent_balance
    FROM public.agent_wallets aw
    JOIN public.agents_management am ON am.id = aw.agent_id
    WHERE am.user_id IS NOT NULL
      AND COALESCE(aw.balance, 0) > 0
      AND COALESCE(aw.currency_type, aw.currency, 'GNF') = 'GNF'
  LOOP
    -- Créer/mettre à jour le wallet dans wallets
    INSERT INTO public.wallets (user_id, balance, currency, created_at, updated_at)
    VALUES (r.user_id, r.agent_balance, 'GNF', NOW(), NOW())
    ON CONFLICT (user_id)
    DO UPDATE SET
      balance    = GREATEST(public.wallets.balance, EXCLUDED.balance),
      updated_at = NOW()
    WHERE public.wallets.balance < EXCLUDED.balance;
  END LOOP;
END;
$$;
