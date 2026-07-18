-- ============================================================
-- 🚨 CRITIQUE — COMMISSION AGENT = PART DU REVENU PLATEFORME (jamais du montant)
--
-- CONSTAT (audit 19/07) :
--  - RETRAIT : déjà conforme (part = % des FRAIS client, l. v_fee_gnf × share).
--  - DÉPÔT : structurellement FAUX — commission = % DU MONTANT déposé
--    (deposit_agent_commission_percent), débitée du wallet PDG, SANS AUCUN
--    frais client. 6 opérations versées à tort (1 663 GNF au total — le
--    plafond journalier a contenu les dégâts, la structure restait explosive).
--
-- MODÈLE PDG (spécification exacte) :
--  commission_client = montant × taux_opération (min/max éventuels), EN PLUS du montant ;
--  part_agent       = commission_client × share_percent_opération ;
--  part_plateforme  = commission_client − part_agent.
--  Retrait : share 25 %. Dépôt : share 20 %. Tout pilotable écran PDG, historisé.
--
-- INVARIANT EN BASE (le bug devient impossible à réintroduire) :
--  agent_share ≤ fee sur agent_cash_operations + CHECK 0-100 sur la config.
-- ============================================================

-- ── 1) CONFIG : la mécanique dépôt = celle du retrait (frais client + part) ──
ALTER TABLE public.agent_cash_config
  ADD COLUMN IF NOT EXISTS deposit_fee_percent numeric NOT NULL DEFAULT 1.0,
  ADD COLUMN IF NOT EXISTS deposit_fee_min numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS deposit_fee_max numeric NOT NULL DEFAULT 30000,
  ADD COLUMN IF NOT EXISTS deposit_agent_share_of_fee numeric NOT NULL DEFAULT 20;

COMMENT ON COLUMN public.agent_cash_config.deposit_agent_commission_percent IS
  'DÉPRÉCIÉ (bug corrigé 19/07) : % du MONTANT déposé payé par le PDG. Plus jamais lu par les RPC — remplacé par deposit_fee_percent (frais client) × deposit_agent_share_of_fee (part agent).';
COMMENT ON COLUMN public.agent_cash_config.deposit_agent_share_of_fee IS
  'Part de l''agent sur les FRAIS de dépôt perçus du client (0-100). Ex: frais 1 000 GNF, part 20 → agent 200, plateforme 800.';
COMMENT ON COLUMN public.agent_cash_config.withdrawal_agent_share_of_fee IS
  'Part de l''agent sur les FRAIS de retrait perçus du client (0-100). Ex: frais 1 000 GNF, part 25 → agent 250, plateforme 750.';

-- CHECK 0-100 (une config à 150 % est REFUSÉE en base)
ALTER TABLE public.agent_cash_config DROP CONSTRAINT IF EXISTS acash_cfg_withdrawal_share_pct;
ALTER TABLE public.agent_cash_config ADD CONSTRAINT acash_cfg_withdrawal_share_pct
  CHECK (withdrawal_agent_share_of_fee >= 0 AND withdrawal_agent_share_of_fee <= 100);
ALTER TABLE public.agent_cash_config DROP CONSTRAINT IF EXISTS acash_cfg_deposit_share_pct;
ALTER TABLE public.agent_cash_config ADD CONSTRAINT acash_cfg_deposit_share_pct
  CHECK (deposit_agent_share_of_fee >= 0 AND deposit_agent_share_of_fee <= 100);
ALTER TABLE public.agent_cash_config DROP CONSTRAINT IF EXISTS acash_cfg_withdrawal_fee_pct;
ALTER TABLE public.agent_cash_config ADD CONSTRAINT acash_cfg_withdrawal_fee_pct
  CHECK (withdrawal_fee_percent >= 0 AND withdrawal_fee_percent <= 100);
ALTER TABLE public.agent_cash_config DROP CONSTRAINT IF EXISTS acash_cfg_deposit_fee_pct;
ALTER TABLE public.agent_cash_config ADD CONSTRAINT acash_cfg_deposit_fee_pct
  CHECK (deposit_fee_percent >= 0 AND deposit_fee_percent <= 100);

-- Valeurs actives selon la spécification PDG (retrait 25 / dépôt 20)
UPDATE public.agent_cash_config
   SET withdrawal_agent_share_of_fee = 25,
       withdrawal_pdg_share_of_fee = 75,
       deposit_fee_percent = 1.0,
       deposit_fee_min = 0,
       deposit_fee_max = 30000,
       deposit_agent_share_of_fee = 20
 WHERE is_active = true;

-- ── 2) INVARIANT « commission agent ≤ frais de l'opération » ──
-- NOT VALID : les 6 dépôts HISTORIQUES du bug (fee=0, share>0) restent en base
-- comme pièces du dossier de régularisation ; toute NOUVELLE ligne (ou mise à
-- jour) est bloquée — le bug est impossible à réintroduire.
ALTER TABLE public.agent_cash_operations DROP CONSTRAINT IF EXISTS acash_ops_share_le_fee;
ALTER TABLE public.agent_cash_operations ADD CONSTRAINT acash_ops_share_le_fee
  CHECK (agent_share IS NULL OR fee IS NULL OR agent_share <= fee) NOT VALID;

-- Nouveau leg 'client_fee_debit' (frais client au dépôt) dans le CHECK du ledger
ALTER TABLE public.agent_cash_ledger DROP CONSTRAINT IF EXISTS agent_cash_ledger_leg_check;
ALTER TABLE public.agent_cash_ledger ADD CONSTRAINT agent_cash_ledger_leg_check
  CHECK (leg = ANY (ARRAY['client_debit', 'client_credit', 'client_fee_debit',
    'agent_wallet_debit', 'agent_wallet_credit', 'agent_float_credit', 'agent_float_debit',
    'pdg_fee_credit', 'pdg_commission_debit', 'agent_commission_credit', 'agent_commission_debit',
    'agent_personal_credit', 'float_merge_to_wallet', 'commission_merge_to_wallet']));

-- ── 3) DÉPÔT v2 — même mécanique que le retrait ──
CREATE OR REPLACE FUNCTION public.agent_cash_deposit(p_agent_id uuid, p_client_user_id uuid, p_amount numeric, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_parent uuid; v_agent RECORD; v_cfg public.agent_cash_config;
  v_aw_id bigint; v_aw_cur text; v_aw_bal numeric;
  v_client_cur text; v_amount_client numeric;
  v_fx jsonb; v_agent_debit numeric; v_floor_agent numeric;
  v_fee_client numeric; v_fee_gnf numeric;
  v_agent_share_gnf numeric; v_comm_fx jsonb; v_comm_agent numeric;
  v_pdg_wallet bigint; v_pdg_bal numeric; v_paid boolean := false;
  v_day_comm numeric := 0; v_to_pending boolean := false; v_reason text := NULL;
  v_credit_res jsonb; v_has_commission boolean;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'MONTANT_INVALIDE'; END IF;
  IF p_client_user_id IS NULL THEN RAISE EXCEPTION 'CLIENT_INTROUVABLE'; END IF;
  v_cfg := public.agent_cash_active_config();
  INSERT INTO public.agent_cash_operations (idempotency_key, operation, agent_id, client_user_id, amount)
  VALUES (p_idempotency_key, 'deposit', p_agent_id, p_client_user_id, p_amount)
  ON CONFLICT (idempotency_key) DO NOTHING RETURNING parent_tx_id INTO v_parent;
  IF v_parent IS NULL THEN
    RETURN (SELECT result FROM public.agent_cash_operations WHERE idempotency_key = p_idempotency_key);
  END IF;
  SELECT * INTO v_agent FROM public.agents_management WHERE id = p_agent_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'AGENT_INTROUVABLE'; END IF;
  IF NOT v_agent.cash_agent_active OR v_agent.cash_agent_suspended THEN RAISE EXCEPTION 'AGENT_INACTIF'; END IF;
  SELECT wallet_id, currency, balance INTO v_aw_id, v_aw_cur, v_aw_bal FROM public._acash_agent_wallet(v_agent.user_id);
  IF v_aw_id IS NULL THEN RAISE EXCEPTION 'WALLET_AGENT_INTROUVABLE'; END IF;
  v_floor_agent := (public._acash_fx(v_cfg.min_wallet_balance_for_cash_ops, 'GNF', v_aw_cur)->>'converted')::numeric;
  IF v_aw_bal < v_floor_agent THEN RAISE EXCEPTION 'SOLDE_AGENT_INSUFFISANT'; END IF;
  SELECT currency INTO v_client_cur FROM public.wallets WHERE user_id = p_client_user_id AND currency IS NOT NULL
    ORDER BY (currency = 'GNF') DESC, updated_at DESC LIMIT 1;
  v_client_cur := COALESCE(v_client_cur, 'GNF');
  v_amount_client := p_amount;

  -- Float de l'agent : il avance le montant déposé (inchangé)
  v_fx := public._acash_fx(v_amount_client, v_client_cur, v_aw_cur);
  v_agent_debit := (v_fx->>'converted')::numeric;
  IF v_aw_bal < v_agent_debit THEN RAISE EXCEPTION 'SOLDE_AGENT_INSUFFISANT'; END IF;
  PERFORM public._acash_debit_wallet(v_aw_id, v_agent_debit, 'SOLDE_AGENT_INSUFFISANT');
  INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency, fx_rate, fx_rate_at, fx_source)
  VALUES (v_parent, 'deposit', 'agent_wallet_debit', p_agent_id, p_client_user_id, v_agent_debit, v_aw_cur,
          (v_fx->>'rate')::numeric, (v_fx->>'rate_at')::timestamptz, v_fx->>'source');

  -- Crédit client du montant déposé (inchangé)
  v_credit_res := public.credit_user_wallet_safe(p_client_user_id, v_amount_client, v_client_cur, 'agent_cash_deposit', v_parent::text);
  INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency)
  VALUES (v_parent, 'deposit', 'client_credit', p_agent_id, p_client_user_id, v_amount_client, v_client_cur);

  -- 💰 FRAIS CLIENT (LE MODÈLE CORRECT) : commission_client = montant × taux (min/max),
  -- jamais plus que le montant, débitée du wallet client EN PLUS du dépôt crédité.
  v_fee_client := least(greatest(round(v_amount_client * v_cfg.deposit_fee_percent / 100.0), v_cfg.deposit_fee_min), v_cfg.deposit_fee_max);
  v_fee_client := least(v_fee_client, v_amount_client);
  IF v_fee_client > 0 THEN
    PERFORM public._acash_debit_wallet(
      (SELECT id FROM public.wallets WHERE user_id = p_client_user_id AND currency = v_client_cur ORDER BY updated_at DESC LIMIT 1),
      v_fee_client, 'SOLDE_INSUFFISANT');
    INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency)
    VALUES (v_parent, 'deposit', 'client_fee_debit', p_agent_id, p_client_user_id, v_fee_client, v_client_cur);
  END IF;
  v_fee_gnf := (public._acash_fx(v_fee_client, v_client_cur, 'GNF')->>'converted')::numeric;

  -- Le REVENU entre au coffre PDG D'ABORD (le coffre se remplit avant de se vider)
  v_pdg_wallet := public.get_pdg_gnf_wallet_id();
  IF v_pdg_wallet IS NULL THEN RAISE EXCEPTION 'PDG_INTROUVABLE'; END IF;
  IF v_fee_gnf > 0 THEN
    PERFORM public._acash_credit_wallet(v_pdg_wallet, v_fee_gnf);
    INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency)
    VALUES (v_parent, 'deposit', 'pdg_fee_credit', p_agent_id, p_client_user_id, v_fee_gnf, 'GNF');
  END IF;

  -- 🎯 PART AGENT = % de la COMMISSION perçue — JAMAIS du montant de l'opération.
  v_agent_share_gnf := round(v_fee_gnf * v_cfg.deposit_agent_share_of_fee / 100.0);

  -- Plafond journalier GLOBAL (dépôts + retraits confondus)
  SELECT COALESCE(sum(agent_share), 0) INTO v_day_comm FROM public.agent_cash_operations
  WHERE agent_id = p_agent_id AND operation IN ('deposit', 'withdrawal')
    AND created_at::date = now()::date AND parent_tx_id <> v_parent;
  IF v_agent.cash_agent_suspended THEN v_to_pending := true; v_reason := 'agent_suspendu';
  ELSIF (v_day_comm + v_agent_share_gnf) > v_cfg.daily_commission_cap_per_agent THEN v_to_pending := true; v_reason := 'plafond_journalier';
  END IF;

  v_comm_fx := public._acash_fx(v_agent_share_gnf, 'GNF', v_aw_cur);
  v_comm_agent := (v_comm_fx->>'converted')::numeric;
  IF v_agent_share_gnf > 0 THEN
    IF v_to_pending THEN
      INSERT INTO public.agent_commission_pending (agent_id, amount, reason, source_parent_tx_id)
      VALUES (p_agent_id, v_agent_share_gnf, v_reason, v_parent);
      INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency, status)
      VALUES (v_parent, 'deposit', 'agent_commission_credit', p_agent_id, p_client_user_id, v_comm_agent, v_aw_cur, 'pending');
    ELSE
      SELECT balance INTO v_pdg_bal FROM public.wallets WHERE id = v_pdg_wallet FOR UPDATE;
      IF v_pdg_bal >= v_agent_share_gnf THEN
        PERFORM public._acash_debit_wallet(v_pdg_wallet, v_agent_share_gnf, 'PDG_INSUFFISANT');
        PERFORM public._acash_credit_wallet(v_aw_id, v_comm_agent);
        INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency)
        VALUES (v_parent, 'deposit', 'pdg_commission_debit', p_agent_id, p_client_user_id, v_agent_share_gnf, 'GNF');
        INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency, fx_rate, fx_rate_at, fx_source)
        VALUES (v_parent, 'deposit', 'agent_commission_credit', p_agent_id, p_client_user_id, v_comm_agent, v_aw_cur,
                (v_comm_fx->>'rate')::numeric, (v_comm_fx->>'rate_at')::timestamptz, v_comm_fx->>'source');
        v_paid := true;
      ELSE
        INSERT INTO public.agent_commission_pending (agent_id, amount, reason, source_parent_tx_id)
        VALUES (p_agent_id, v_agent_share_gnf, 'pdg_insuffisant', v_parent);
        INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency, status)
        VALUES (v_parent, 'deposit', 'agent_commission_credit', p_agent_id, p_client_user_id, v_comm_agent, v_aw_cur, 'pending');
      END IF;
    END IF;
  ELSE
    INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency, status)
    VALUES (v_parent, 'deposit', 'agent_commission_credit', p_agent_id, p_client_user_id, 0, v_aw_cur, 'completed');
  END IF;

  SELECT EXISTS (SELECT 1 FROM public.agent_cash_ledger WHERE parent_tx_id = v_parent AND leg = 'agent_commission_credit') INTO v_has_commission;
  IF NOT v_has_commission THEN RAISE EXCEPTION 'COMMISSION_MANQUANTE: depot % sans commission tracee', v_parent; END IF;

  UPDATE public.agent_cash_operations
  SET fee = v_fee_gnf, agent_share = v_agent_share_gnf, pdg_share = v_fee_gnf - v_agent_share_gnf,
      result = jsonb_build_object(
        'success', true, 'parent_tx_id', v_parent, 'client_credited', v_amount_client, 'client_currency', v_client_cur,
        'fee_client', v_fee_client, 'agent_debited', v_agent_debit, 'agent_currency', v_aw_cur,
        'agent_commission', v_comm_agent, 'commission_paid', v_paid, 'rate', (v_fx->>'rate')::numeric,
        'quarantined', COALESCE((v_credit_res->>'quarantined')::numeric, 0))
  WHERE parent_tx_id = v_parent;
  RETURN (SELECT result FROM public.agent_cash_operations WHERE parent_tx_id = v_parent);
END $function$;

-- ── 4) RETRAIT : part 25 % pilotée par la config (formule déjà conforme) +
--      plafond journalier GLOBAL (dépôts + retraits confondus) ──
-- (seule la ligne du cumul journalier change : operation IN ('deposit','withdrawal'))
CREATE OR REPLACE FUNCTION public.agent_cash_withdrawal(p_agent_id uuid, p_client_user_id uuid, p_amount numeric, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_parent uuid; v_agent RECORD; v_cfg public.agent_cash_config;
  v_client_wallet bigint; v_client_cur text; v_pdg_wallet bigint;
  v_aw_id bigint; v_aw_cur text; v_aw_bal numeric; v_floor_agent numeric;
  v_amount_gnf numeric; v_fee_gnf numeric; v_agent_share_gnf numeric;
  v_win_amount numeric := 0; v_win_fees numeric := 0; v_cum_fee numeric;
  v_day_comm numeric := 0; v_to_pending boolean := false; v_reason text := NULL;
  v_client_day numeric := 0; v_has_commission boolean;
  v_fee_client numeric; v_fx_agent jsonb; v_agent_credit numeric;
  v_comm_fx jsonb; v_comm_agent numeric;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'MONTANT_INVALIDE'; END IF;
  IF p_client_user_id IS NULL THEN RAISE EXCEPTION 'CLIENT_INTROUVABLE'; END IF;
  v_cfg := public.agent_cash_active_config();
  INSERT INTO public.agent_cash_operations (idempotency_key, operation, agent_id, client_user_id, amount)
  VALUES (p_idempotency_key, 'withdrawal', p_agent_id, p_client_user_id, p_amount)
  ON CONFLICT (idempotency_key) DO NOTHING RETURNING parent_tx_id INTO v_parent;
  IF v_parent IS NULL THEN
    RETURN (SELECT result FROM public.agent_cash_operations WHERE idempotency_key = p_idempotency_key);
  END IF;
  SELECT * INTO v_agent FROM public.agents_management WHERE id = p_agent_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'AGENT_INTROUVABLE'; END IF;
  IF NOT v_agent.cash_agent_active THEN RAISE EXCEPTION 'AGENT_INACTIF'; END IF;
  SELECT wallet_id, currency, balance INTO v_aw_id, v_aw_cur, v_aw_bal FROM public._acash_agent_wallet(v_agent.user_id);
  IF v_aw_id IS NULL THEN RAISE EXCEPTION 'WALLET_AGENT_INTROUVABLE'; END IF;
  v_floor_agent := (public._acash_fx(v_cfg.min_wallet_balance_for_cash_ops, 'GNF', v_aw_cur)->>'converted')::numeric;
  IF v_aw_bal < v_floor_agent THEN RAISE EXCEPTION 'SOLDE_AGENT_INSUFFISANT'; END IF;
  SELECT id, currency INTO v_client_wallet, v_client_cur FROM public.wallets
  WHERE user_id = p_client_user_id ORDER BY (currency = 'GNF') DESC, updated_at DESC LIMIT 1;
  IF v_client_wallet IS NULL THEN RAISE EXCEPTION 'WALLET_CLIENT_INTROUVABLE'; END IF;
  v_client_cur := COALESCE(v_client_cur, 'GNF');
  SELECT COALESCE(sum(amount), 0) INTO v_client_day FROM public.agent_cash_operations
  WHERE operation = 'withdrawal' AND client_user_id = p_client_user_id
    AND created_at > now() - interval '24 hours' AND parent_tx_id <> v_parent;
  v_amount_gnf := (public._acash_fx(v_client_day + p_amount, v_client_cur, 'GNF')->>'converted')::numeric;
  IF v_amount_gnf > COALESCE(v_cfg.max_client_withdrawal_daily, 5000000) THEN
    RAISE EXCEPTION 'PLAFOND_CLIENT_ATTEINT';
  END IF;
  SELECT COALESCE(sum(amount),0), COALESCE(sum(fee),0) INTO v_win_amount, v_win_fees
  FROM public.agent_cash_operations
  WHERE operation = 'withdrawal' AND agent_id = p_agent_id AND client_user_id = p_client_user_id
    AND created_at > now() - make_interval(mins => v_cfg.anti_split_window_minutes)
    AND parent_tx_id <> v_parent;
  v_cum_fee := least(greatest(round((v_win_amount + p_amount) * v_cfg.withdrawal_fee_percent / 100.0), v_cfg.withdrawal_fee_min), v_cfg.withdrawal_fee_max);
  v_fee_client := greatest(v_cum_fee - v_win_fees, 0);
  v_fee_gnf := (public._acash_fx(v_fee_client, v_client_cur, 'GNF')->>'converted')::numeric;
  v_agent_share_gnf := round(v_fee_gnf * v_cfg.withdrawal_agent_share_of_fee / 100.0);
  PERFORM public._acash_debit_wallet(v_client_wallet, p_amount + v_fee_client, 'SOLDE_INSUFFISANT');
  INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency)
  VALUES (v_parent, 'withdrawal', 'client_debit', p_agent_id, p_client_user_id, p_amount + v_fee_client, v_client_cur);
  v_fx_agent := public._acash_fx(p_amount, v_client_cur, v_aw_cur);
  v_agent_credit := (v_fx_agent->>'converted')::numeric;
  PERFORM public._acash_credit_wallet(v_aw_id, v_agent_credit);
  INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency, fx_rate, fx_rate_at, fx_source)
  VALUES (v_parent, 'withdrawal', 'agent_wallet_credit', p_agent_id, p_client_user_id, v_agent_credit, v_aw_cur,
          (v_fx_agent->>'rate')::numeric, (v_fx_agent->>'rate_at')::timestamptz, v_fx_agent->>'source');
  v_pdg_wallet := public.get_pdg_gnf_wallet_id();
  IF v_pdg_wallet IS NULL THEN RAISE EXCEPTION 'PDG_INTROUVABLE'; END IF;
  IF v_fee_gnf > 0 THEN
    PERFORM public._acash_credit_wallet(v_pdg_wallet, v_fee_gnf);
    INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency)
    VALUES (v_parent, 'withdrawal', 'pdg_fee_credit', p_agent_id, p_client_user_id, v_fee_gnf, 'GNF');
  END IF;
  SELECT COALESCE(sum(agent_share),0) INTO v_day_comm FROM public.agent_cash_operations
  WHERE agent_id = p_agent_id AND operation IN ('deposit', 'withdrawal') AND created_at::date = now()::date AND parent_tx_id <> v_parent;
  IF v_agent.cash_agent_suspended THEN v_to_pending := true; v_reason := 'agent_suspendu';
  ELSIF (v_day_comm + v_agent_share_gnf) > v_cfg.daily_commission_cap_per_agent THEN v_to_pending := true; v_reason := 'plafond_journalier';
  END IF;
  v_comm_fx := public._acash_fx(v_agent_share_gnf, 'GNF', v_aw_cur);
  v_comm_agent := (v_comm_fx->>'converted')::numeric;
  IF v_agent_share_gnf > 0 THEN
    IF v_to_pending THEN
      INSERT INTO public.agent_commission_pending (agent_id, amount, reason, source_parent_tx_id)
      VALUES (p_agent_id, v_agent_share_gnf, v_reason, v_parent);
      INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency, status)
      VALUES (v_parent, 'withdrawal', 'agent_commission_credit', p_agent_id, p_client_user_id, v_comm_agent, v_aw_cur, 'pending');
      INSERT INTO public.agent_audit_log_safe(severity, event, detail)
      VALUES ('warning', 'agent_cash_commission_pending', jsonb_build_object('agent_id', p_agent_id, 'amount_gnf', v_agent_share_gnf, 'reason', v_reason, 'parent_tx_id', v_parent));
    ELSE
      PERFORM public._acash_debit_wallet(v_pdg_wallet, v_agent_share_gnf, 'PDG_INSUFFISANT');
      PERFORM public._acash_credit_wallet(v_aw_id, v_comm_agent);
      INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency)
      VALUES (v_parent, 'withdrawal', 'pdg_commission_debit', p_agent_id, p_client_user_id, v_agent_share_gnf, 'GNF');
      INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency, fx_rate, fx_rate_at, fx_source)
      VALUES (v_parent, 'withdrawal', 'agent_commission_credit', p_agent_id, p_client_user_id, v_comm_agent, v_aw_cur,
              (v_comm_fx->>'rate')::numeric, (v_comm_fx->>'rate_at')::timestamptz, v_comm_fx->>'source');
    END IF;
  ELSE
    INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency, status)
    VALUES (v_parent, 'withdrawal', 'agent_commission_credit', p_agent_id, p_client_user_id, 0, v_aw_cur, 'completed');
  END IF;
  SELECT EXISTS (SELECT 1 FROM public.agent_cash_ledger WHERE parent_tx_id = v_parent AND leg = 'agent_commission_credit') INTO v_has_commission;
  IF NOT v_has_commission THEN RAISE EXCEPTION 'COMMISSION_MANQUANTE: retrait % sans commission tracee', v_parent; END IF;
  UPDATE public.agent_cash_operations
  SET fee = v_fee_gnf, agent_share = v_agent_share_gnf, pdg_share = v_fee_gnf - v_agent_share_gnf,
      result = jsonb_build_object('success', true, 'parent_tx_id', v_parent, 'amount', p_amount, 'client_currency', v_client_cur,
        'fee_client', v_fee_client, 'agent_credited', v_agent_credit, 'agent_currency', v_aw_cur,
        'agent_share', v_comm_agent, 'commission_pending', v_to_pending, 'rate', (v_fx_agent->>'rate')::numeric)
  WHERE parent_tx_id = v_parent;
  RETURN (SELECT result FROM public.agent_cash_operations WHERE parent_tx_id = v_parent);
END $function$;

-- ── 5) CONFIG UPDATE v2 : porte TOUS les paramètres (les nouveaux taux dépôt
--      + ceux que l'ancienne version PERDAIT à chaque changement : sponsorship,
--      self_withdrawal, activation) — modifiable sans redéploiement, historisé. ──
CREATE OR REPLACE FUNCTION public.agent_cash_config_update(p_changes jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_cur public.agent_cash_config; v_new_id uuid; v_w_share numeric;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  v_cur := public.agent_cash_active_config();
  -- Part PDG auto-complémentée (contrainte agent+pdg=100) : changer la part agent suffit.
  v_w_share := COALESCE((p_changes->>'withdrawal_agent_share_of_fee')::numeric, v_cur.withdrawal_agent_share_of_fee);
  UPDATE public.agent_cash_config SET is_active = false WHERE is_active = true;
  INSERT INTO public.agent_cash_config (
    withdrawal_fee_percent, withdrawal_fee_min, withdrawal_fee_max,
    withdrawal_agent_share_of_fee, withdrawal_pdg_share_of_fee,
    deposit_fee_percent, deposit_fee_min, deposit_fee_max, deposit_agent_share_of_fee,
    deposit_agent_commission_percent,
    activation_float_threshold, min_float_for_operations,
    daily_commission_cap_per_agent, anti_split_window_minutes,
    max_client_withdrawal_daily, min_wallet_balance_for_cash_ops,
    allow_agent_sponsorship, max_sub_agents_per_sponsor, self_withdrawal_fee_percent,
    is_active, created_by)
  VALUES (
    COALESCE((p_changes->>'withdrawal_fee_percent')::numeric, v_cur.withdrawal_fee_percent),
    COALESCE((p_changes->>'withdrawal_fee_min')::numeric, v_cur.withdrawal_fee_min),
    COALESCE((p_changes->>'withdrawal_fee_max')::numeric, v_cur.withdrawal_fee_max),
    v_w_share,
    COALESCE((p_changes->>'withdrawal_pdg_share_of_fee')::numeric, 100 - v_w_share),
    COALESCE((p_changes->>'deposit_fee_percent')::numeric, v_cur.deposit_fee_percent),
    COALESCE((p_changes->>'deposit_fee_min')::numeric, v_cur.deposit_fee_min),
    COALESCE((p_changes->>'deposit_fee_max')::numeric, v_cur.deposit_fee_max),
    COALESCE((p_changes->>'deposit_agent_share_of_fee')::numeric, v_cur.deposit_agent_share_of_fee),
    v_cur.deposit_agent_commission_percent, -- déprécié, jamais modifié, jamais lu
    COALESCE((p_changes->>'activation_float_threshold')::numeric, v_cur.activation_float_threshold),
    COALESCE((p_changes->>'min_float_for_operations')::numeric, v_cur.min_float_for_operations),
    COALESCE((p_changes->>'daily_commission_cap_per_agent')::numeric, v_cur.daily_commission_cap_per_agent),
    COALESCE((p_changes->>'anti_split_window_minutes')::int, v_cur.anti_split_window_minutes),
    COALESCE((p_changes->>'max_client_withdrawal_daily')::numeric, v_cur.max_client_withdrawal_daily),
    COALESCE((p_changes->>'min_wallet_balance_for_cash_ops')::numeric, v_cur.min_wallet_balance_for_cash_ops),
    COALESCE((p_changes->>'allow_agent_sponsorship')::boolean, v_cur.allow_agent_sponsorship),
    COALESCE((p_changes->>'max_sub_agents_per_sponsor')::int, v_cur.max_sub_agents_per_sponsor),
    COALESCE((p_changes->>'self_withdrawal_fee_percent')::numeric, v_cur.self_withdrawal_fee_percent),
    true, auth.uid())
  RETURNING id INTO v_new_id;
  RETURN jsonb_build_object('success', true, 'config_id', v_new_id);
END $function$;
