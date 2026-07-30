-- ============================================================================
-- MODÈLE THIERNO (30/07/2026) — Commission agent de dépôt PAYÉE D'AVANCE AU DÉPÔT
-- ============================================================================
-- Décision PDG (verbatim) : « chaque dépôt l'agent doit gagner 20% du revenu de la plateforme,
-- malgré que le dépôt soit gratuit. Ex : dépôt 500 000 → frais de retrait 5 000 → l'agent gagne
-- 20% d'avance = 1 000. Puis au retrait 500 000, frais 5 000 → l'agent de retrait touche encore
-- 25% = 1 250 et la plateforme garde 2 750. »
--
-- AVANT (bug) : la commission de dépôt = 20% du FRAIS DE DÉPÔT (= 0, dépôt gratuit) → l'agent
--   touchait 0 ; sa part 20% était DIFFÉRÉE au retrait (trigger trg_acash_settle_deposit_lots).
-- APRÈS : la commission de dépôt = 20% (d_share) du FRAIS DE RETRAIT ATTENDU sur la somme déposée
--   (w_pct/w_min/w_max), AVANCÉE par le coffre PDG DÈS LE DÉPÔT. Le versement différé est RETIRÉ
--   (trigger supprimé) → jamais de double paie. Économie nette identique (20/25/55), timing changé.
-- Le coffre PDG avance la part au dépôt (−1 000) et se rembourse au retrait (garde 75% du frais,
--   soit 3 750 ; net 2 750 = 55%). « Je (PDG) ne gagne qu'au retrait » — respecté.
-- ============================================================================

-- ── 1) CHECK obsolète : agent_share ≤ fee valait pour l'ancien modèle (commission = %du frais perçu).
--    Sous le modèle d'avance, la part (1 000) dépasse le frais de dépôt (0) → on retire ce CHECK.
--    L'intégrité reste garantie : la part est bornée = 20% d'un frais de retrait calculé (déterministe).
ALTER TABLE public.agent_cash_operations DROP CONSTRAINT IF EXISTS acash_ops_share_le_fee;

-- ── 2) Retrait du versement DIFFÉRÉ au retrait (sinon l'agent serait payé 2×).
--    La table agent_cash_deposit_lots et les fonctions sont CONSERVÉES (historique) mais ne
--    déclenchent plus de paiement. NE PAS re-créer ce trigger sans revoir le modèle d'avance.
DROP TRIGGER IF EXISTS trg_acash_settle_deposit_lots ON public.agent_cash_operations;

-- ── 3) agent_cash_deposit : commission d'avance = 20% du frais de RETRAIT de la somme déposée ──
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
  v_wd_fee_client := least(greatest(round(v_amount_client * (v_rules->>'w_pct')::numeric / 100.0), (v_rules->>'w_min')::numeric), (v_rules->>'w_max')::numeric);
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

-- Après validation PDG : appliquer, puis un dépôt 500 000 → agent +1 000 immédiat (coffre −1 000).
