-- ============================================================================
-- RÉGULARISATION AGENT-CASH — reprise des commissions dépôt versées à tort
-- (ancienne formule : % du MONTANT déposé, financée par le coffre PDG,
--  sans aucun frais client — corrigée par 20260719130000).
--
-- ⚠️  NE PAS EXÉCUTER SANS VALIDATION EXPLICITE DU PDG.
--     Ce script REPREND de l'argent sur les wallets de 3 agents :
--       VND0003 (Thierno Souleymane Bah) :  86 XOF  (4 opérations)
--       CLT0015 (Cert Agent)             : 200 GNF  (1 opération)
--       VND0002 (Abdoulaye Conte)        : 153 GNF  (1 opération)
--     et recrédite le coffre PDG de 1 663 GNF (contre-valeurs aux taux
--     d'origine, montants exacts des legs pdg_commission_debit).
--
-- Sûreté : transaction unique (tout ou rien), idempotent (rejouable sans
-- double reprise), guard de solde par wallet (échec explicite si insuffisant),
-- trace complète (agent_cash_ledger + wallet_transactions).
-- ============================================================================
BEGIN;

-- 0. Legs de reversement autorisés dans le ledger
ALTER TABLE public.agent_cash_ledger DROP CONSTRAINT IF EXISTS agent_cash_ledger_leg_check;
ALTER TABLE public.agent_cash_ledger ADD CONSTRAINT agent_cash_ledger_leg_check CHECK (leg = ANY (ARRAY[
  'client_debit','client_credit','client_fee_debit','agent_wallet_debit','agent_wallet_credit',
  'agent_float_credit','agent_float_debit','pdg_fee_credit','pdg_commission_debit',
  'agent_commission_credit','agent_commission_debit','agent_personal_credit',
  'float_merge_to_wallet','commission_merge_to_wallet',
  'commission_reversal_debit','commission_reversal_credit'
]));

DO $$
DECLARE
  r RECORD;
  v_agent_wallet bigint;
  v_agent_ccy text;
  v_reprise_agent numeric;     -- montant à reprendre, devise du wallet agent
  v_credit_pdg numeric;        -- contre-valeur GNF exacte (leg d'origine)
  v_pdg_wallet bigint;
  v_bal numeric;
  v_total_pdg numeric := 0;
  v_nb int := 0;
BEGIN
  v_pdg_wallet := public.get_pdg_gnf_wallet_id();
  IF v_pdg_wallet IS NULL THEN RAISE EXCEPTION 'COFFRE_PDG_INTROUVABLE'; END IF;

  FOR r IN
    SELECT o.parent_tx_id, o.agent_id, am.user_id AS agent_user_id
    FROM public.agent_cash_operations o
    JOIN public.agents_management am ON am.id = o.agent_id
    WHERE o.operation = 'deposit' AND COALESCE(o.fee, 0) = 0 AND COALESCE(o.agent_share, 0) > 0
    ORDER BY o.created_at
  LOOP
    -- Idempotence : déjà reversé → sauter
    IF EXISTS (SELECT 1 FROM public.agent_cash_ledger
               WHERE parent_tx_id = r.parent_tx_id AND leg = 'commission_reversal_debit') THEN
      RAISE NOTICE 'op % : déjà régularisée, ignorée', r.parent_tx_id;
      CONTINUE;
    END IF;

    -- Montants EXACTS des legs d'origine (aucun recalcul FX)
    SELECT amount, currency INTO v_reprise_agent, v_agent_ccy
    FROM public.agent_cash_ledger
    WHERE parent_tx_id = r.parent_tx_id AND leg = 'agent_commission_credit';
    SELECT amount INTO v_credit_pdg
    FROM public.agent_cash_ledger
    WHERE parent_tx_id = r.parent_tx_id AND leg = 'pdg_commission_debit';
    IF v_reprise_agent IS NULL OR v_credit_pdg IS NULL THEN
      RAISE EXCEPTION 'op % : legs d''origine introuvables — régularisation impossible', r.parent_tx_id;
    END IF;

    -- Wallet agent dans la devise du versement d'origine
    SELECT id INTO v_agent_wallet FROM public.wallets
    WHERE user_id = r.agent_user_id AND currency = v_agent_ccy;
    IF v_agent_wallet IS NULL THEN
      RAISE EXCEPTION 'op % : wallet % de l''agent % introuvable', r.parent_tx_id, v_agent_ccy, r.agent_user_id;
    END IF;

    -- Débit agent (guard solde) + crédit coffre PDG
    SELECT balance INTO v_bal FROM public.wallets WHERE id = v_agent_wallet FOR UPDATE;
    IF v_bal < v_reprise_agent THEN
      RAISE EXCEPTION 'op % : solde agent insuffisant (% < %)', r.parent_tx_id, v_bal, v_reprise_agent;
    END IF;
    UPDATE public.wallets SET balance = balance - v_reprise_agent, updated_at = now() WHERE id = v_agent_wallet;
    UPDATE public.wallets SET balance = COALESCE(balance, 0) + v_credit_pdg, updated_at = now() WHERE id = v_pdg_wallet;

    -- Trace ledger agent-cash (miroir inverse des legs d'origine)
    INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency, status)
    VALUES
      (r.parent_tx_id, 'deposit', 'commission_reversal_debit',  r.agent_id, NULL, v_reprise_agent, v_agent_ccy, 'completed'),
      (r.parent_tx_id, 'deposit', 'commission_reversal_credit', r.agent_id, NULL, v_credit_pdg,   'GNF',       'completed');

    -- Trace wallet_transactions (plateforme)
    INSERT INTO public.wallet_transactions
      (transaction_id, sender_wallet_id, receiver_wallet_id, sender_user_id, amount, fee, net_amount,
       currency, transaction_type, status, description, metadata, completed_at)
    VALUES
      ('acash-regul-' || r.parent_tx_id, v_agent_wallet, v_pdg_wallet, r.agent_user_id,
       v_reprise_agent, 0, v_reprise_agent, v_agent_ccy, 'commission', 'completed',
       'Régularisation commission dépôt agent-cash (ancienne formule % du montant) — reprise vers coffre PDG',
       jsonb_build_object('parent_tx_id', r.parent_tx_id, 'credit_pdg_gnf', v_credit_pdg,
                          'regularisation', '20260718-agent-cash-commission-revenu'),
       now());

    v_total_pdg := v_total_pdg + v_credit_pdg;
    v_nb := v_nb + 1;
    RAISE NOTICE 'op % : repris % % à l''agent, coffre PDG +% GNF', r.parent_tx_id, v_reprise_agent, v_agent_ccy, v_credit_pdg;
  END LOOP;

  RAISE NOTICE '=== RÉGULARISATION : % opérations, coffre PDG +% GNF (attendu : 6 ops / 1663 GNF au premier passage) ===', v_nb, v_total_pdg;
END $$;

-- Contrôle final : plus aucun trop-versé non régularisé
DO $$
DECLARE v_restant int;
BEGIN
  SELECT count(*) INTO v_restant
  FROM public.agent_cash_operations o
  WHERE o.operation = 'deposit' AND COALESCE(o.fee, 0) = 0 AND COALESCE(o.agent_share, 0) > 0
    AND NOT EXISTS (SELECT 1 FROM public.agent_cash_ledger l
                    WHERE l.parent_tx_id = o.parent_tx_id AND l.leg = 'commission_reversal_debit');
  IF v_restant <> 0 THEN RAISE EXCEPTION 'CONTRÔLE ÉCHOUÉ : % opérations non régularisées', v_restant; END IF;
  RAISE NOTICE 'CONTRÔLE OK : tous les trop-versés sont régularisés.';
END $$;

COMMIT;
