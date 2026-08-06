-- ═══════════════════════════════════════════════════════════════════════════
-- FIX COMMISSION DEVISES DÉCIMALES (EUR/USD/SLE…) — l'agent-cash arrondissait À
-- L'UNITÉ (round(x)) : correct pour GNF/XOF (0 décimale), FAUX pour EUR/USD/SLE
-- (2 décimales) → 20 EUR × 2% = 0,40 → round → 0 → commission agent = 0.
-- Migration NOUVELLE (aucune existante éditée).
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Helper : nombre de décimales d'une devise ────────────────────────────────
-- RÈGLE : (a) currencies.decimal_places si présent ; (b) sinon 0 si ZÉRO-DÉCIMALE,
-- sinon **2** (JAMAIS 0 par défaut — sinon SLE/NGN/GHS/… absentes reprendraient le bug).
-- ⚠️ La liste ci-dessous doit rester STRICTEMENT identique à ZERO_DECIMAL_CURRENCIES de
-- src/config/currencyConfig.ts (front) ET backend src/config/currencyConfig.ts.
-- TOUTE MODIF DOIT ÊTRE RÉPLIQUÉE AUX 2 FICHIERS TS. SLE (nouveau leone) = 2 ; SLL (ancien
-- leone, encore listé dans FX_CROSS_CURRENCIES) = 2 aussi (jamais zéro-décimale).
CREATE OR REPLACE FUNCTION public._ccy_decimals(p_ccy text)
RETURNS int LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT COALESCE(
    (SELECT decimal_places FROM public.currencies WHERE upper(code) = upper(p_ccy)),
    CASE WHEN upper(p_ccy) = ANY (ARRAY[
      'GNF','XOF','XAF','BIF','DJF','KMF','MGA','RWF','UGX',
      'CLP','JPY','KRW','PYG','VND','VUV','XPF'
    ]) THEN 0 ELSE 2 END
  );
$$;

-- ── Seed currencies : devises des marchés 224Solutions absentes (source primaire) ──
INSERT INTO public.currencies (code, name, symbol, decimal_places) VALUES
  ('SLE', 'Leone (nouveau)', 'Le', 2), ('SLL', 'Leone (ancien)', 'Le', 2), ('NGN', 'Naira', 'NGN', 2),
  ('GHS', 'Cedi', 'GHS', 2), ('LRD', 'Dollar liberien', 'LRD', 2), ('GMD', 'Dalasi', 'GMD', 2),
  ('CVE', 'Escudo cap-verdien', 'CVE', 2), ('XAF', 'Franc CFA (CEMAC)', 'FCFA', 0),
  ('GBP', 'Livre sterling', 'GBP', 2), ('EUR', 'Euro', 'EUR', 2), ('USD', 'Dollar americain', 'USD', 2)
ON CONFLICT (code) DO NOTHING;


-- ── _acash_fx corrigé ──
CREATE OR REPLACE FUNCTION public._acash_fx(p_amount numeric, p_from text, p_to text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_rate numeric; v_at timestamptz;
  v_from_usd numeric; v_usd_to numeric; v_at1 timestamptz; v_at2 timestamptz;
  v_conv numeric;
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR upper(p_from) = upper(p_to) THEN
    RETURN jsonb_build_object('converted', round(p_amount, public._ccy_decimals(p_to)), 'rate', 1, 'rate_at', now(), 'source', 'same', 'remainder', 0);
  END IF;
  SELECT CASE WHEN cer.from_currency = p_from THEN cer.rate ELSE 1.0 / NULLIF(cer.rate,0) END, cer.retrieved_at
  INTO v_rate, v_at
  FROM public.currency_exchange_rates cer
  WHERE ((cer.from_currency = p_from AND cer.to_currency = p_to)
      OR (cer.from_currency = p_to AND cer.to_currency = p_from))
    AND cer.is_active = true
  ORDER BY cer.retrieved_at DESC LIMIT 1;
  IF v_rate IS NULL OR v_rate <= 0 THEN
    SELECT CASE WHEN cer.from_currency = p_from THEN cer.rate ELSE 1.0 / NULLIF(cer.rate,0) END, cer.retrieved_at
    INTO v_from_usd, v_at1 FROM public.currency_exchange_rates cer
    WHERE ((cer.from_currency = p_from AND cer.to_currency = 'USD') OR (cer.from_currency = 'USD' AND cer.to_currency = p_from))
      AND cer.is_active = true ORDER BY cer.retrieved_at DESC LIMIT 1;
    SELECT CASE WHEN cer.from_currency = 'USD' THEN cer.rate ELSE 1.0 / NULLIF(cer.rate,0) END, cer.retrieved_at
    INTO v_usd_to, v_at2 FROM public.currency_exchange_rates cer
    WHERE ((cer.from_currency = 'USD' AND cer.to_currency = p_to) OR (cer.from_currency = p_to AND cer.to_currency = 'USD'))
      AND cer.is_active = true ORDER BY cer.retrieved_at DESC LIMIT 1;
    IF v_from_usd IS NOT NULL AND v_from_usd > 0 AND v_usd_to IS NOT NULL AND v_usd_to > 0 THEN
      v_rate := v_from_usd * v_usd_to;
      v_at := least(v_at1, v_at2);
    END IF;
  END IF;
  IF v_rate IS NULL OR v_rate <= 0 THEN
    RAISE EXCEPTION 'TAUX_INDISPONIBLE: taux introuvable % -> %', p_from, p_to;
  END IF;
  IF v_at IS NULL OR v_at < now() - interval '24 hours' THEN
    RAISE EXCEPTION 'TAUX_INDISPONIBLE: taux perime % -> % (> 24h)', p_from, p_to;
  END IF;
  v_conv := round(p_amount * v_rate, public._ccy_decimals(p_to));
  RETURN jsonb_build_object('converted', v_conv, 'rate', v_rate, 'rate_at', v_at,
    'source', 'currency_exchange_rates', 'remainder', (p_amount * v_rate) - v_conv);
END $function$;


-- ── agent_cash_deposit corrigé ──
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
  v_wd_fee_client numeric; v_wd_fee_gnf numeric;               -- NOUVEAU : frais de retrait attendu
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

  -- 💰 FRAIS CLIENT AU DÉPÔT (dépôt gratuit par défaut : d_pct=0 → v_fee_client=0). Inchangé.
  v_fee_client := least(greatest(round(v_amount_client * (v_rules->>'d_pct')::numeric / 100.0, public._ccy_decimals(v_client_cur)), (v_rules->>'d_min')::numeric), (v_rules->>'d_max')::numeric);
  v_fee_client := least(v_fee_client, v_amount_client);
  IF v_fee_client > 0 THEN
    PERFORM public._acash_debit_wallet(
      (SELECT id FROM public.wallets WHERE user_id = p_client_user_id AND currency = v_client_cur ORDER BY updated_at DESC LIMIT 1),
      v_fee_client, 'SOLDE_INSUFFISANT');
    INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency)
    VALUES (v_parent, 'deposit', 'client_fee_debit', p_agent_id, p_client_user_id, v_fee_client, v_client_cur);
  END IF;
  v_fee_gnf := (public._acash_fx(v_fee_client, v_client_cur, 'GNF')->>'converted')::numeric;

  -- Le frais de dépôt éventuel entre au coffre PDG (inchangé ; = 0 si dépôt gratuit)
  v_pdg_wallet := public.get_pdg_gnf_wallet_id();
  IF v_pdg_wallet IS NULL THEN RAISE EXCEPTION 'PDG_INTROUVABLE'; END IF;
  IF v_fee_gnf > 0 THEN
    PERFORM public._acash_credit_wallet(v_pdg_wallet, v_fee_gnf);
    INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency)
    VALUES (v_parent, 'deposit', 'pdg_fee_credit', p_agent_id, p_client_user_id, v_fee_gnf, 'GNF');
  END IF;

  -- 🎯 MODÈLE THIERNO : part d'avance = d_share% du FRAIS DE RETRAIT que vaudra la somme déposée
  -- (w_pct/w_min/w_max), et NON du frais de dépôt. C'est LA correction (avant : × v_fee_gnf = 0).
  v_wd_fee_client := least(greatest(round(v_amount_client * (v_rules->>'w_pct')::numeric / 100.0, public._ccy_decimals(v_client_cur)), (v_rules->>'w_min')::numeric), (v_rules->>'w_max')::numeric);
  v_wd_fee_gnf := (public._acash_fx(v_wd_fee_client, v_client_cur, 'GNF')->>'converted')::numeric;
  v_agent_share_gnf := round(v_wd_fee_gnf * (v_rules->>'d_share')::numeric / 100.0);

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

  -- Résumé op : fee = frais CLIENT réellement perçu (0 si gratuit) ; agent_share = avance versée ;
  -- pdg_share = mouvement NET du coffre au dépôt (négatif = avance sortie, remboursée au retrait).
  UPDATE public.agent_cash_operations
  SET fee = v_fee_gnf, agent_share = v_agent_share_gnf, pdg_share = v_fee_gnf - v_agent_share_gnf,
      result = jsonb_build_object(
        'success', true, 'parent_tx_id', v_parent, 'client_credited', v_amount_client, 'client_currency', v_client_cur,
        'fee_client', v_fee_client, 'agent_debited', v_agent_debit, 'agent_currency', v_aw_cur,
        'agent_commission', v_comm_agent, 'commission_paid', v_paid, 'commission_basis_wd_fee_gnf', v_wd_fee_gnf,
        'rate', (v_fx->>'rate')::numeric, 'rules_source', v_rules->>'source',
        'quarantined', COALESCE((v_credit_res->>'quarantined')::numeric, 0))
  WHERE parent_tx_id = v_parent;
  RETURN (SELECT result FROM public.agent_cash_operations WHERE parent_tx_id = v_parent);
END $function$;


-- ── agent_cash_withdrawal corrigé ──
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
  v_cum_fee := least(greatest(round((v_win_amount + p_amount) * (v_rules->>'w_pct')::numeric / 100.0, public._ccy_decimals(v_client_cur)), (v_rules->>'w_min')::numeric), (v_rules->>'w_max')::numeric);
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
