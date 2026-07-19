-- ============================================================================
-- AGENT-CASH — MODÈLE DE COMMISSION UNIVERSEL, GRILLE PAR DEVISE PILOTÉE PDG
--
-- Le modèle (commission client EN PLUS du montant → part_agent = % de la
-- COMMISSION → plateforme = le reste, invariant agent_share ≤ fee) était déjà
-- appliqué partout (dépôt/retrait, same-currency ET cross-devise au taux gelé).
-- SEUL trou restant : les frais min/max venaient de la config GLOBALE (magnitude
-- GNF) et étaient appliqués tels quels au montant en devise CLIENT — faux dès
-- que le client n'est pas en GNF.
--
-- Ce chantier introduit une GRILLE PAR DEVISE (taux + planchers/plafonds + parts
-- dans la devise concernée) avec un DÉFAUT global : quand une devise n'a pas de
-- ligne dédiée, on retombe sur le défaut dont les min/max sont CONVERTIS dans la
-- devise du client (jamais de devise sans règle, jamais de plancher faux).
-- Le pourcentage et les parts sont neutres à la devise ; seuls min/max le sont.
-- ============================================================================

-- 1. GRILLE PAR DEVISE (versionnée : lignes historisées, une active par devise)
CREATE TABLE IF NOT EXISTS public.agent_cash_currency_config (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  currency text NOT NULL,
  withdrawal_fee_percent numeric NOT NULL,
  withdrawal_fee_min numeric NOT NULL DEFAULT 0,
  withdrawal_fee_max numeric NOT NULL,
  withdrawal_agent_share_of_fee numeric NOT NULL,
  deposit_fee_percent numeric NOT NULL,
  deposit_fee_min numeric NOT NULL DEFAULT 0,
  deposit_fee_max numeric NOT NULL,
  deposit_agent_share_of_fee numeric NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid,
  CONSTRAINT acash_grid_wd_pct   CHECK (withdrawal_fee_percent >= 0 AND withdrawal_fee_percent <= 100),
  CONSTRAINT acash_grid_dep_pct  CHECK (deposit_fee_percent >= 0 AND deposit_fee_percent <= 100),
  CONSTRAINT acash_grid_wd_share CHECK (withdrawal_agent_share_of_fee >= 0 AND withdrawal_agent_share_of_fee <= 100),
  CONSTRAINT acash_grid_dep_share CHECK (deposit_agent_share_of_fee >= 0 AND deposit_agent_share_of_fee <= 100),
  CONSTRAINT acash_grid_wd_bounds  CHECK (withdrawal_fee_min >= 0 AND withdrawal_fee_max >= withdrawal_fee_min),
  CONSTRAINT acash_grid_dep_bounds CHECK (deposit_fee_min >= 0 AND deposit_fee_max >= deposit_fee_min)
);
-- Une seule ligne active par devise (upsert = désactive l'ancienne + insère).
CREATE UNIQUE INDEX IF NOT EXISTS acash_grid_one_active_per_currency
  ON public.agent_cash_currency_config (currency) WHERE is_active;

ALTER TABLE public.agent_cash_currency_config ENABLE ROW LEVEL SECURITY;
-- Backend-only (service_role) ; aucune policy pour anon/authenticated.
DROP POLICY IF EXISTS acash_grid_service_all ON public.agent_cash_currency_config;
CREATE POLICY acash_grid_service_all ON public.agent_cash_currency_config
  FOR ALL TO service_role USING (true) WITH CHECK (true);

-- 2. RÉSOLVEUR : règles de frais/parts pour une devise donnée.
--    Ligne de grille active si elle existe (valeurs DÉJÀ dans cette devise),
--    sinon le DÉFAUT global — min/max convertis GNF→devise (identité si GNF).
CREATE OR REPLACE FUNCTION public._acash_currency_rules(p_currency text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_ccy text := COALESCE(p_currency, 'GNF');
  v_g public.agent_cash_currency_config;
  v_cfg public.agent_cash_config;
  v_wd_min numeric; v_wd_max numeric; v_dep_min numeric; v_dep_max numeric;
BEGIN
  SELECT * INTO v_g FROM public.agent_cash_currency_config
  WHERE currency = v_ccy AND is_active = true LIMIT 1;
  IF FOUND THEN
    RETURN jsonb_build_object(
      'source', 'grid', 'currency', v_ccy,
      'w_pct', v_g.withdrawal_fee_percent, 'w_min', v_g.withdrawal_fee_min, 'w_max', v_g.withdrawal_fee_max,
      'w_share', v_g.withdrawal_agent_share_of_fee,
      'd_pct', v_g.deposit_fee_percent, 'd_min', v_g.deposit_fee_min, 'd_max', v_g.deposit_fee_max,
      'd_share', v_g.deposit_agent_share_of_fee);
  END IF;
  -- Défaut : la config globale. Les min/max sont exprimés en GNF (devise de
  -- référence) → convertis dans la devise du client pour un plancher juste.
  v_cfg := public.agent_cash_active_config();
  IF upper(v_ccy) = 'GNF' THEN
    v_wd_min := v_cfg.withdrawal_fee_min; v_wd_max := v_cfg.withdrawal_fee_max;
    v_dep_min := v_cfg.deposit_fee_min;   v_dep_max := v_cfg.deposit_fee_max;
  ELSE
    v_wd_min := (public._acash_fx(v_cfg.withdrawal_fee_min, 'GNF', v_ccy)->>'converted')::numeric;
    v_wd_max := (public._acash_fx(v_cfg.withdrawal_fee_max, 'GNF', v_ccy)->>'converted')::numeric;
    v_dep_min := (public._acash_fx(v_cfg.deposit_fee_min, 'GNF', v_ccy)->>'converted')::numeric;
    v_dep_max := (public._acash_fx(v_cfg.deposit_fee_max, 'GNF', v_ccy)->>'converted')::numeric;
  END IF;
  RETURN jsonb_build_object(
    'source', 'default', 'currency', v_ccy,
    'w_pct', v_cfg.withdrawal_fee_percent, 'w_min', v_wd_min, 'w_max', v_wd_max,
    'w_share', v_cfg.withdrawal_agent_share_of_fee,
    'd_pct', v_cfg.deposit_fee_percent, 'd_min', v_dep_min, 'd_max', v_dep_max,
    'd_share', v_cfg.deposit_agent_share_of_fee);
END $function$;

REVOKE ALL ON FUNCTION public._acash_currency_rules(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._acash_currency_rules(text) TO service_role;

-- 3. LECTURE PDG : défaut + toutes les lignes de grille actives.
CREATE OR REPLACE FUNCTION public.agent_cash_currency_grid()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v_cfg public.agent_cash_config; v_rows jsonb;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  v_cfg := public.agent_cash_active_config();
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'currency', currency,
      'withdrawal_fee_percent', withdrawal_fee_percent, 'withdrawal_fee_min', withdrawal_fee_min, 'withdrawal_fee_max', withdrawal_fee_max,
      'withdrawal_agent_share_of_fee', withdrawal_agent_share_of_fee,
      'deposit_fee_percent', deposit_fee_percent, 'deposit_fee_min', deposit_fee_min, 'deposit_fee_max', deposit_fee_max,
      'deposit_agent_share_of_fee', deposit_agent_share_of_fee,
      'created_at', created_at) ORDER BY currency), '[]'::jsonb)
  INTO v_rows FROM public.agent_cash_currency_config WHERE is_active = true;
  RETURN jsonb_build_object(
    'default', jsonb_build_object(
      'withdrawal_fee_percent', v_cfg.withdrawal_fee_percent, 'withdrawal_fee_min', v_cfg.withdrawal_fee_min, 'withdrawal_fee_max', v_cfg.withdrawal_fee_max,
      'withdrawal_agent_share_of_fee', v_cfg.withdrawal_agent_share_of_fee,
      'deposit_fee_percent', v_cfg.deposit_fee_percent, 'deposit_fee_min', v_cfg.deposit_fee_min, 'deposit_fee_max', v_cfg.deposit_fee_max,
      'deposit_agent_share_of_fee', v_cfg.deposit_agent_share_of_fee),
    'rows', v_rows);
END $function$;

REVOKE ALL ON FUNCTION public.agent_cash_currency_grid() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.agent_cash_currency_grid() TO service_role;

-- 4. UPSERT d'une ligne de grille (versionné + historisé + auth PDG).
--    Les champs absents de p_changes héritent de la ligne active existante,
--    sinon du DÉFAUT global (min/max convertis dans la devise).
CREATE OR REPLACE FUNCTION public.agent_cash_currency_config_upsert(p_currency text, p_changes jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_ccy text := upper(trim(p_currency));
  v_prev public.agent_cash_currency_config;
  v_def jsonb; v_new_id uuid;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  IF v_ccy IS NULL OR v_ccy = '' THEN RAISE EXCEPTION 'DEVISE_INVALIDE'; END IF;
  SELECT * INTO v_prev FROM public.agent_cash_currency_config WHERE currency = v_ccy AND is_active = true LIMIT 1;
  -- Base de repli = ligne active existante, sinon le défaut résolu pour la devise.
  v_def := public._acash_currency_rules(v_ccy);

  UPDATE public.agent_cash_currency_config SET is_active = false WHERE currency = v_ccy AND is_active = true;
  INSERT INTO public.agent_cash_currency_config (
    currency,
    withdrawal_fee_percent, withdrawal_fee_min, withdrawal_fee_max, withdrawal_agent_share_of_fee,
    deposit_fee_percent, deposit_fee_min, deposit_fee_max, deposit_agent_share_of_fee,
    is_active, created_by)
  VALUES (
    v_ccy,
    COALESCE((p_changes->>'withdrawal_fee_percent')::numeric, v_prev.withdrawal_fee_percent, (v_def->>'w_pct')::numeric),
    COALESCE((p_changes->>'withdrawal_fee_min')::numeric, v_prev.withdrawal_fee_min, (v_def->>'w_min')::numeric),
    COALESCE((p_changes->>'withdrawal_fee_max')::numeric, v_prev.withdrawal_fee_max, (v_def->>'w_max')::numeric),
    COALESCE((p_changes->>'withdrawal_agent_share_of_fee')::numeric, v_prev.withdrawal_agent_share_of_fee, (v_def->>'w_share')::numeric),
    COALESCE((p_changes->>'deposit_fee_percent')::numeric, v_prev.deposit_fee_percent, (v_def->>'d_pct')::numeric),
    COALESCE((p_changes->>'deposit_fee_min')::numeric, v_prev.deposit_fee_min, (v_def->>'d_min')::numeric),
    COALESCE((p_changes->>'deposit_fee_max')::numeric, v_prev.deposit_fee_max, (v_def->>'d_max')::numeric),
    COALESCE((p_changes->>'deposit_agent_share_of_fee')::numeric, v_prev.deposit_agent_share_of_fee, (v_def->>'d_share')::numeric),
    true, auth.uid())
  RETURNING id INTO v_new_id;
  RETURN jsonb_build_object('success', true, 'currency', v_ccy, 'config_id', v_new_id);
END $function$;

REVOKE ALL ON FUNCTION public.agent_cash_currency_config_upsert(text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.agent_cash_currency_config_upsert(text, jsonb) TO service_role;

-- 5. SUPPRESSION d'une ligne (la devise retombe sur le DÉFAUT). Historisé.
CREATE OR REPLACE FUNCTION public.agent_cash_currency_config_delete(p_currency text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v_ccy text := upper(trim(p_currency)); v_n int;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  UPDATE public.agent_cash_currency_config SET is_active = false WHERE currency = v_ccy AND is_active = true;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN jsonb_build_object('success', true, 'currency', v_ccy, 'removed', v_n);
END $function$;

REVOKE ALL ON FUNCTION public.agent_cash_currency_config_delete(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.agent_cash_currency_config_delete(text) TO service_role;

-- 6. DÉPÔT v3 — frais/parts résolus PAR DEVISE du client (grille ou défaut).
--    (corps verbatim de la v2 live, seule la résolution des frais change)
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
  v_credit_res jsonb; v_has_commission boolean; v_rules jsonb;
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
  -- 📐 Règles de frais/parts DANS LA DEVISE DU CLIENT (grille dédiée ou défaut converti)
  v_rules := public._acash_currency_rules(v_client_cur);

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

  -- 💰 FRAIS CLIENT (LE MODÈLE CORRECT) : commission = montant × taux (min/max de
  -- la devise du client), jamais plus que le montant, débités EN PLUS du dépôt.
  v_fee_client := least(greatest(round(v_amount_client * (v_rules->>'d_pct')::numeric / 100.0), (v_rules->>'d_min')::numeric), (v_rules->>'d_max')::numeric);
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
  v_agent_share_gnf := round(v_fee_gnf * (v_rules->>'d_share')::numeric / 100.0);

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
        'rules_source', v_rules->>'source',
        'quarantined', COALESCE((v_credit_res->>'quarantined')::numeric, 0))
  WHERE parent_tx_id = v_parent;
  RETURN (SELECT result FROM public.agent_cash_operations WHERE parent_tx_id = v_parent);
END $function$;

-- 7. RETRAIT v3 — frais/parts résolus PAR DEVISE du client (grille ou défaut).
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
  v_comm_fx jsonb; v_comm_agent numeric; v_rules jsonb;
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
  -- 📐 Règles de frais/parts DANS LA DEVISE DU CLIENT (grille dédiée ou défaut converti)
  v_rules := public._acash_currency_rules(v_client_cur);
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
  v_cum_fee := least(greatest(round((v_win_amount + p_amount) * (v_rules->>'w_pct')::numeric / 100.0), (v_rules->>'w_min')::numeric), (v_rules->>'w_max')::numeric);
  v_fee_client := greatest(v_cum_fee - v_win_fees, 0);
  v_fee_gnf := (public._acash_fx(v_fee_client, v_client_cur, 'GNF')->>'converted')::numeric;
  v_agent_share_gnf := round(v_fee_gnf * (v_rules->>'w_share')::numeric / 100.0);
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
        'agent_share', v_comm_agent, 'commission_pending', v_to_pending, 'rate', (v_fx_agent->>'rate')::numeric,
        'rules_source', v_rules->>'source')
  WHERE parent_tx_id = v_parent;
  RETURN (SELECT result FROM public.agent_cash_operations WHERE parent_tx_id = v_parent);
END $function$;

-- 8. HARNAIS — l'invariant agent_share ≤ fee ajouté à la réconciliation
--    (compte les lignes fee>0 où agent_share > fee : doit rester 0 sur TOUTES
--    les devises ; les 6 lignes legacy fee=0 sont hors périmètre, préservées).
CREATE OR REPLACE FUNCTION public.agent_cash_reconciliation_check()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v_unbalanced int; v_missing_comm int; v_untraced_fx int; v_legacy_float int; v_share_gt_fee int; v_report jsonb;
BEGIN
  SELECT count(*) INTO v_unbalanced FROM (
    SELECT l.parent_tx_id,
      sum(CASE WHEN l.leg LIKE '%_debit' THEN l.amount ELSE 0 END) AS deb,
      sum(CASE WHEN l.leg LIKE '%_credit' THEN l.amount ELSE 0 END) AS cred
    FROM public.agent_cash_ledger l
    WHERE l.status = 'completed' AND l.operation IN ('deposit','withdrawal')
      AND NOT EXISTS (SELECT 1 FROM public.agent_cash_ledger x WHERE x.parent_tx_id = l.parent_tx_id AND x.fx_rate IS NOT NULL)
    GROUP BY l.parent_tx_id
    HAVING abs(sum(CASE WHEN l.leg LIKE '%_debit' THEN l.amount ELSE 0 END)
             - sum(CASE WHEN l.leg LIKE '%_credit' THEN l.amount ELSE 0 END)) > 1
  ) d;
  SELECT count(*) INTO v_missing_comm FROM public.agent_cash_operations o
  WHERE o.operation IN ('deposit','withdrawal')
    AND NOT EXISTS (SELECT 1 FROM public.agent_cash_ledger l WHERE l.parent_tx_id = o.parent_tx_id AND l.leg = 'agent_commission_credit');
  -- FX non tracé : SEULS les legs réellement CONVERTIS (côté agent) portent un
  -- taux. Les legs natifs en devise du client (client_debit/credit/fee) ne sont
  -- pas des conversions → fx_rate NULL légitime, hors périmètre.
  SELECT count(*) INTO v_untraced_fx FROM public.agent_cash_ledger
  WHERE operation IN ('deposit','withdrawal') AND currency <> 'GNF' AND fx_rate IS NULL
    AND leg IN ('agent_wallet_credit','agent_wallet_debit','agent_commission_credit');
  SELECT count(*) INTO v_legacy_float FROM public.agent_cash_ledger
  WHERE leg IN ('agent_float_credit','agent_float_debit')
    AND created_at > (SELECT max(created_at) FROM public.agent_cash_ledger WHERE leg = 'float_merge_to_wallet');
  -- Invariant UNIVERSEL : part agent ≤ commission (en GNF, donc valable toutes devises).
  SELECT count(*) INTO v_share_gt_fee FROM public.agent_cash_operations
  WHERE operation IN ('deposit','withdrawal') AND fee > 0 AND agent_share > fee;
  v_report := jsonb_build_object('generated_at', now(),
    'checks', jsonb_build_array(
      jsonb_build_object('key','ledger_unbalanced','label','Operations (par devise) debits != credits','severity','critical','count',v_unbalanced,'observed',v_unbalanced),
      jsonb_build_object('key','missing_commission','label','Operations sans commission tracee','severity','critical','count',v_missing_comm,'observed',v_missing_comm),
      jsonb_build_object('key','fx_untraced','label','Legs convertis sans taux trace','severity','critical','count',v_untraced_fx,'observed',v_untraced_fx),
      jsonb_build_object('key','share_gt_fee','label','Part agent > commission (invariant universel)','severity','critical','count',v_share_gt_fee,'observed',v_share_gt_fee),
      jsonb_build_object('key','legacy_float','label','Legs float apres migration (interdit)','severity','warning','count',v_legacy_float,'observed',v_legacy_float)
    ));
  IF v_unbalanced > 0 OR v_missing_comm > 0 OR v_untraced_fx > 0 OR v_share_gt_fee > 0 OR v_legacy_float > 0 THEN
    PERFORM public.agent_audit_log_safe('critical', 'agent_cash_reconciliation_anomaly', v_report);
  END IF;
  RETURN v_report;
END $function$;
