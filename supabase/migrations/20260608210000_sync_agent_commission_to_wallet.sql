-- ============================================================================
-- SYNCHRO commission agent -> wallet DÉPENSABLE (fix B)
-- ----------------------------------------------------------------------------
-- Problème : credit_agent_commission crédite la commission UNIQUEMENT dans
-- `agent_wallets` (suivi des commissions). Mais le wallet réellement
-- DÉPENSABLE de l'agent (retrait/transfert), lu par AgentWalletManagement,
-- est `wallets`. La synchro entre les deux n'existait plus -> l'agent voyait
-- ses commissions en stats mais ne pouvait pas les utiliser.
--
-- Correctif : credit_agent_wallet_gnf crédite TOUJOURS agent_wallets (inchangé)
-- ET crédite aussi le wallet principal de l'agent via le primitif sûr
-- `credit_user_wallet_safe` (1 seul wallet par user, conversion GNF -> devise
-- du wallet, pas de doublon de clé). Idempotent : credit_agent_wallet_gnf
-- n'est appelé qu'après une insertion de commission NON dupliquée.
--
-- ⚠️ Ne backfill PAS les commissions passées (risque de double-crédit) : ce fix
--    ne concerne que les commissions FUTURES. Pour les anciennes (présentes dans
--    agent_wallets mais jamais arrivées dans wallets), une réconciliation
--    manuelle ciblée peut être faite séparément si nécessaire.
--
-- Non destructif, rejouable (CREATE OR REPLACE).
-- ============================================================================

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

  -- 1) Wallet agent dédié (suivi des commissions) — comportement INCHANGÉ.
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
    balance = COALESCE(public.agent_wallets.balance, 0) + EXCLUDED.balance,
    currency = 'GNF',
    wallet_status = COALESCE(public.agent_wallets.wallet_status, 'active'),
    updated_at = NOW();

  -- 2) NOUVEAU : créditer aussi le wallet PRINCIPAL (dépensable) de l'agent,
  --    via le primitif sûr (verrou, conversion GNF->devise wallet, 1 wallet/user).
  SELECT user_id INTO v_user_id
  FROM public.agents_management
  WHERE id = p_agent_id;

  IF v_user_id IS NOT NULL THEN
    PERFORM public.credit_user_wallet_safe(v_user_id, ROUND(p_amount, 2), 'GNF');
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.credit_agent_wallet_gnf(uuid, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.credit_agent_wallet_gnf(uuid, numeric) TO service_role;
