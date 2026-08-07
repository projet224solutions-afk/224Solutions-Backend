-- ═══════════════════════════════════════════════════════════════════════════
-- CHANTIER 2.2 (maillon profond) — la commission d'affiliation est CRÉDITÉE DANS LA DEVISE
-- DU WALLET DE L'AGENT, conversion GNF→devise agent TRACÉE par Fatome (_acash_fx : taux+date+
-- source, garde de fraîcheur 24 h). Si ce leg n'a PAS de taux frais → PRÉ-VOL fail-closed :
-- aucune mutation, retour fx_pending → le caller met EN ATTENTE (jamais de spot non tracé,
-- jamais perdu). `credit_user_wallet_safe` (primitif partagé escrow/dépôts/remboursements) N'EST
-- PAS modifié : la conversion tracée se fait AVANT, dans credit_agent_wallet_gnf.
-- Migration NOUVELLE, additive. Reproduit credit_agent_commission (20260630_09) À L'IDENTIQUE +
-- 5 éditions : pré-vol FX (sous-agent + direct) et passage du log_id aux 3 crédits.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

-- 1) Traçage de la conversion GNF→devise agent (additif ; lignes historiques NULL = documenté).
ALTER TABLE public.agent_commissions_log
  ADD COLUMN IF NOT EXISTS credited_currency text,
  ADD COLUMN IF NOT EXISTS credited_amount   numeric,
  ADD COLUMN IF NOT EXISTS fx_rate           numeric,
  ADD COLUMN IF NOT EXISTS fx_rate_at        timestamptz,
  ADD COLUMN IF NOT EXISTS fx_source         text;

-- 2) Pré-vol FX (fail-closed) : le leg GNF→devise-wallet de l'agent a-t-il un taux FRAIS ?
CREATE OR REPLACE FUNCTION public._agent_fx_ready(p_agent_id uuid)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fx$
DECLARE v_user uuid; v_cur text;
BEGIN
  SELECT user_id INTO v_user FROM public.agents_management WHERE id = p_agent_id;
  IF v_user IS NULL THEN RETURN true; END IF;  -- pas de wallet dépensable → credit_user_wallet_safe créera un GNF
  SELECT currency INTO v_cur FROM public.wallets WHERE user_id = v_user ORDER BY (currency='GNF') DESC, id LIMIT 1;
  IF v_cur IS NULL OR v_cur = 'GNF' THEN RETURN true; END IF;  -- agent guinéen : pas de conversion
  PERFORM public._acash_fx(1, 'GNF', v_cur);  -- lève TAUX_INDISPONIBLE si pas de taux frais (garde 24 h)
  RETURN true;
EXCEPTION WHEN OTHERS THEN RETURN false;
END; $fx$;
REVOKE ALL ON FUNCTION public._agent_fx_ready(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._agent_fx_ready(uuid) TO service_role;

-- 3) credit_agent_wallet_gnf : crédit du wallet dépensable DANS LA DEVISE DE L'AGENT, conversion
--    TRACÉE (_acash_fx), + écriture de la trace dans agent_commissions_log (si log_id fourni).
--    On DROP l'ancienne signature 2-args (évite un doublon de surcharge = alerte money_integrity).
DROP FUNCTION IF EXISTS public.credit_agent_wallet_gnf(uuid, numeric);
CREATE OR REPLACE FUNCTION public.credit_agent_wallet_gnf(
  p_agent_id uuid, p_amount numeric, p_log_id uuid DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $wg$
DECLARE v_user_id uuid; v_cur text; v_fx jsonb; v_conv numeric; v_rate numeric; v_rate_at timestamptz; v_src text;
BEGIN
  IF p_agent_id IS NULL OR COALESCE(p_amount, 0) <= 0 THEN RETURN; END IF;

  -- a) Wallet agent dédié (suivi des commissions) — comportement INCHANGÉ (toujours GNF).
  INSERT INTO public.agent_wallets (agent_id, balance, currency, wallet_status, currency_type, updated_at)
  VALUES (p_agent_id, ROUND(p_amount, 2), 'GNF', 'active', 'GNF', NOW())
  ON CONFLICT (agent_id, currency_type) DO UPDATE SET
    balance = COALESCE(public.agent_wallets.balance, 0) + EXCLUDED.balance,
    currency = 'GNF', wallet_status = COALESCE(public.agent_wallets.wallet_status, 'active'), updated_at = NOW();

  -- b) Wallet DÉPENSABLE de l'agent, DANS SA DEVISE — conversion tracée par Fatome.
  SELECT user_id INTO v_user_id FROM public.agents_management WHERE id = p_agent_id;
  IF v_user_id IS NOT NULL THEN
    SELECT currency INTO v_cur FROM public.wallets WHERE user_id = v_user_id ORDER BY (currency='GNF') DESC, id LIMIT 1;
    IF v_cur IS NULL OR v_cur = 'GNF' THEN
      -- Agent guinéen (ou pas encore de wallet → GNF) : aucune conversion, trace = identité.
      PERFORM public.credit_user_wallet_safe(v_user_id, ROUND(p_amount, 2), 'GNF');
      v_conv := ROUND(p_amount, 2); v_cur := 'GNF'; v_rate := 1; v_rate_at := now(); v_src := 'identity';
    ELSE
      -- Conversion GNF→devise agent TRACÉE (garde 24 h) ; on crédite DÉJÀ dans la devise du wallet
      -- (p_from = devise wallet → credit_user_wallet_safe ne re-convertit pas). _acash_fx lève si pas
      -- de taux frais — mais le pré-vol de credit_agent_commission l'a déjà écarté (fail-closed).
      v_fx := public._acash_fx(ROUND(p_amount, 2), 'GNF', v_cur);
      v_conv := (v_fx->>'converted')::numeric;
      v_rate := (v_fx->>'rate')::numeric; v_rate_at := (v_fx->>'rate_at')::timestamptz; v_src := v_fx->>'source';
      PERFORM public.credit_user_wallet_safe(v_user_id, v_conv, v_cur);
    END IF;

    -- c) Trace de la conversion sur la ligne de commission (rate + date + source).
    IF p_log_id IS NOT NULL THEN
      UPDATE public.agent_commissions_log
      SET credited_currency = v_cur, credited_amount = v_conv, fx_rate = v_rate, fx_rate_at = v_rate_at, fx_source = v_src
      WHERE id = p_log_id;
    END IF;
  END IF;
END; $wg$;
REVOKE ALL ON FUNCTION public.credit_agent_wallet_gnf(uuid, numeric, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.credit_agent_wallet_gnf(uuid, numeric, uuid) TO service_role;

-- 4) credit_agent_commission : + pré-vol FX (sous-agent + direct) + passage du log_id aux 3 crédits.
CREATE OR REPLACE FUNCTION public.credit_agent_commission(
  p_user_id uuid, p_amount numeric, p_source_type text,
  p_transaction_id uuid DEFAULT NULL::uuid, p_metadata jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $cac$
DECLARE
  v_affiliation RECORD; v_agent RECORD; v_parent_agent RECORD; v_has_parent boolean := false;
  v_sub_rate numeric; v_principal_rate numeric; v_max_total_rate numeric; v_total_rate numeric; v_scale numeric;
  v_sub_applied numeric; v_principal_applied numeric;
  v_agent_commission numeric := 0; v_parent_commission numeric := 0;
  v_agent_log_id uuid; v_parent_log_id uuid; v_any_inserted boolean := false;
  v_agent_duplicate boolean := false; v_parent_duplicate boolean := false;
  v_currency text := COALESCE(NULLIF(p_metadata->>'currency', ''), 'GNF');  -- devise de BASE (GNF) du log
  v_pdg_user_id uuid; v_pdg_balance numeric; v_planned numeric; v_total_agent numeric;
  v_low_threshold numeric := public.pdg_setting_numeric('pdg_wallet_low_threshold', 100000);
BEGIN
  IF p_user_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Utilisateur requis'); END IF;
  IF COALESCE(p_amount, 0) <= 0 THEN RETURN jsonb_build_object('success', false, 'error', 'Montant invalide'); END IF;

  v_sub_rate       := GREATEST(0, LEAST(public.pdg_setting_numeric('agent_sub_commission_percent', 15), 100));
  v_principal_rate := GREATEST(0, LEAST(public.pdg_setting_numeric('agent_principal_commission_percent', 5), 100));
  v_max_total_rate := GREATEST(0, LEAST(public.pdg_setting_numeric('max_total_agent_commission_percentage', 100), 100));

  SELECT * INTO v_affiliation FROM public.get_user_agent(p_user_id);
  IF v_affiliation.agent_id IS NULL THEN
    RETURN jsonb_build_object('success', true, 'has_agent', false, 'message', 'Utilisateur non affilie a un agent');
  END IF;
  SELECT * INTO v_agent FROM public.agents_management WHERE id = v_affiliation.agent_id AND is_active = true;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Agent non trouve ou inactif'); END IF;

  IF p_transaction_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.agent_commissions_log WHERE transaction_id = p_transaction_id AND related_user_id = p_user_id
  ) THEN
    RETURN jsonb_build_object('success', true, 'has_agent', true, 'already_processed', true);
  END IF;

  SELECT user_id INTO v_pdg_user_id FROM public.pdg_management WHERE is_active = true ORDER BY created_at NULLS LAST LIMIT 1;
  IF v_pdg_user_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'PDG_INTROUVABLE', 'has_agent', true); END IF;
  SELECT balance INTO v_pdg_balance FROM public.wallets WHERE user_id = v_pdg_user_id AND currency = 'GNF' FOR UPDATE;
  IF v_pdg_balance IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'PDG_WALLET_GNF_INTROUVABLE', 'has_agent', true); END IF;

  -- ========================= SOUS-AGENT =========================
  IF v_agent.type_agent = 'sous_agent' THEN
    IF v_agent.parent_agent_id IS NOT NULL THEN
      SELECT * INTO v_parent_agent FROM public.agents_management WHERE id = v_agent.parent_agent_id AND is_active = true;
      IF FOUND THEN v_has_parent := true; END IF;
    END IF;

    -- 🔒 PRÉ-VOL FX (fail-closed) : chaque agent crédité doit avoir un taux frais GNF→sa devise, sinon
    -- on ne touche à RIEN (pas de log, pas de crédit, pas de débit PDG) → fx_pending → mise en ATTENTE.
    IF NOT public._agent_fx_ready(v_agent.id)
       OR (v_has_parent AND NOT public._agent_fx_ready(v_parent_agent.id)) THEN
      RETURN jsonb_build_object('success', false, 'fx_pending', true, 'error', 'AGENT_FX_UNAVAILABLE', 'has_agent', true);
    END IF;

    v_sub_applied := v_sub_rate;
    v_principal_applied := CASE WHEN v_has_parent THEN v_principal_rate ELSE 0 END;
    v_total_rate := v_sub_applied + v_principal_applied;
    IF v_total_rate > v_max_total_rate AND v_total_rate > 0 THEN
      v_scale := v_max_total_rate / v_total_rate;
      v_sub_applied := ROUND(v_sub_applied * v_scale, 4);
      v_principal_applied := ROUND(v_principal_applied * v_scale, 4);
    END IF;

    v_planned := ROUND(p_amount * (v_sub_applied / 100), 2)
                 + CASE WHEN v_has_parent THEN ROUND(p_amount * (v_principal_applied / 100), 2) ELSE 0 END;
    IF v_planned > v_pdg_balance THEN
      RAISE NOTICE 'Solde PDG insuffisant (% < %) — commission sous-agent non versee', v_pdg_balance, v_planned;
      BEGIN
        PERFORM public.create_notification(v_pdg_user_id, 'pdg_commission_blocked', '⛔ Commission agent bloquée',
          format('Une commission agent (%s GNF) n''a pas pu être versée : solde PDG insuffisant. Approvisionnez le wallet PDG.', ROUND(v_planned, 2)),
          jsonb_build_object('needed', ROUND(v_planned, 2), 'balance', ROUND(v_pdg_balance, 2), 'source_type', p_source_type, 'reference', p_transaction_id));
      EXCEPTION WHEN OTHERS THEN NULL; END;
      RETURN jsonb_build_object('success', false, 'error', 'SOLDE_PDG_INSUFFISANT', 'has_agent', true);
    END IF;

    v_agent_commission := ROUND(p_amount * (v_sub_applied / 100), 2);
    IF v_agent_commission > 0 THEN
      INSERT INTO public.agent_commissions_log (agent_id, amount, source_type, related_user_id, transaction_id,
        description, status, commission_rate, transaction_amount, currency)
      VALUES (v_agent.id, v_agent_commission, p_source_type, p_user_id, p_transaction_id,
        'Commission sous-agent ' || v_sub_applied || '% des frais sur ' || p_source_type,
        'validated', v_sub_applied, ROUND(p_amount, 2), v_currency)
      ON CONFLICT DO NOTHING RETURNING id INTO v_agent_log_id;
      IF v_agent_log_id IS NULL THEN v_agent_duplicate := true; v_agent_commission := 0;
      ELSE
        PERFORM public.credit_agent_wallet_gnf(v_agent.id, v_agent_commission, v_agent_log_id);
        v_any_inserted := true;
        IF v_agent.user_id IS NOT NULL THEN
          BEGIN PERFORM public.create_notification(v_agent.user_id, 'commission_received', 'Commission reçue 💰',
            format('Vous avez reçu une commission de %s GNF (achat de votre filleul).', v_agent_commission),
            jsonb_build_object('amount', v_agent_commission, 'source', p_source_type, 'reference', p_transaction_id, 'role', 'sous_agent'));
          EXCEPTION WHEN OTHERS THEN NULL; END;
        END IF;
      END IF;
    END IF;

    IF v_has_parent THEN
      v_parent_commission := ROUND(p_amount * (v_principal_applied / 100), 2);
      IF v_parent_commission > 0 THEN
        INSERT INTO public.agent_commissions_log (agent_id, amount, source_type, related_user_id, transaction_id,
          description, status, commission_rate, transaction_amount, currency)
        VALUES (v_parent_agent.id, v_parent_commission, p_source_type, p_user_id, p_transaction_id,
          'Commission agent principal ' || v_principal_applied || '% des frais via sous-agent ' || v_agent.name,
          'validated', v_principal_applied, ROUND(p_amount, 2), v_currency)
        ON CONFLICT DO NOTHING RETURNING id INTO v_parent_log_id;
        IF v_parent_log_id IS NULL THEN v_parent_duplicate := true; v_parent_commission := 0;
        ELSE
          PERFORM public.credit_agent_wallet_gnf(v_parent_agent.id, v_parent_commission, v_parent_log_id);
          v_any_inserted := true;
          IF v_parent_agent.user_id IS NOT NULL THEN
            BEGIN PERFORM public.create_notification(v_parent_agent.user_id, 'commission_received', 'Commission reçue 💰',
              format('Vous avez reçu %s GNF (commission sur l''activité de votre sous-agent).', v_parent_commission),
              jsonb_build_object('amount', v_parent_commission, 'source', p_source_type, 'reference', p_transaction_id, 'role', 'agent_principal'));
            EXCEPTION WHEN OTHERS THEN NULL; END;
          END IF;
        END IF;
      END IF;
    END IF;

    v_total_agent := ROUND(COALESCE(v_agent_commission, 0) + COALESCE(v_parent_commission, 0), 2);
    IF v_total_agent > 0 THEN
      UPDATE public.wallets SET balance = balance - v_total_agent, updated_at = now() WHERE user_id = v_pdg_user_id AND currency = 'GNF';
      BEGIN
        INSERT INTO public.platform_revenue (revenue_type, amount, source_transaction_id, metadata)
        VALUES ('agent_commission_payout', -v_total_agent, p_transaction_id,
                jsonb_build_object('user_id', p_user_id, 'source_type', p_source_type, 'agent_id', v_agent.id, 'parent_agent_id', v_agent.parent_agent_id));
      EXCEPTION WHEN OTHERS THEN NULL; END;
      IF (v_pdg_balance - v_total_agent) < v_low_threshold THEN
        BEGIN PERFORM public.create_notification(v_pdg_user_id, 'pdg_wallet_low', '⚠️ Solde PDG bas',
          format('Le wallet PDG est bas (%s GNF). Approvisionnez-le pour ne pas bloquer les commissions agents.', ROUND(v_pdg_balance - v_total_agent, 2)),
          jsonb_build_object('balance', ROUND(v_pdg_balance - v_total_agent, 2), 'threshold', v_low_threshold));
        EXCEPTION WHEN OTHERS THEN NULL; END;
      END IF;
    END IF;

    RETURN jsonb_build_object('success', true, 'has_agent', true,
      'already_processed', (NOT v_any_inserted AND (v_agent_duplicate OR v_parent_duplicate)),
      'agent_type', 'sous_agent', 'agent_id', v_agent.id, 'agent_name', v_agent.name,
      'agent_commission', v_agent_commission, 'agent_rate', v_sub_applied,
      'parent_agent_id', v_agent.parent_agent_id, 'parent_commission', COALESCE(v_parent_commission, 0),
      'parent_rate', v_principal_applied, 'parent_already_processed', v_parent_duplicate,
      'capped_total_rate', v_max_total_rate, 'pdg_debited', v_total_agent,
      'total_commissions', v_agent_commission + COALESCE(v_parent_commission, 0));
  END IF;

  -- ========================= AGENT PRINCIPAL DIRECT =========================
  -- 🔒 PRÉ-VOL FX (fail-closed) avant toute mutation.
  IF NOT public._agent_fx_ready(v_agent.id) THEN
    RETURN jsonb_build_object('success', false, 'fx_pending', true, 'error', 'AGENT_FX_UNAVAILABLE', 'has_agent', true);
  END IF;

  v_total_rate := LEAST(v_sub_rate + v_principal_rate, v_max_total_rate);
  v_planned := ROUND(p_amount * (v_total_rate / 100), 2);
  IF v_planned > v_pdg_balance THEN
    RAISE NOTICE 'Solde PDG insuffisant (% < %) — commission agent non versee', v_pdg_balance, v_planned;
    BEGIN
      PERFORM public.create_notification(v_pdg_user_id, 'pdg_commission_blocked', '⛔ Commission agent bloquée',
        format('Une commission agent (%s GNF) n''a pas pu être versée : solde PDG insuffisant. Approvisionnez le wallet PDG.', ROUND(v_planned, 2)),
        jsonb_build_object('needed', ROUND(v_planned, 2), 'balance', ROUND(v_pdg_balance, 2), 'source_type', p_source_type, 'reference', p_transaction_id));
    EXCEPTION WHEN OTHERS THEN NULL; END;
    RETURN jsonb_build_object('success', false, 'error', 'SOLDE_PDG_INSUFFISANT', 'has_agent', true);
  END IF;

  v_agent_commission := ROUND(p_amount * (v_total_rate / 100), 2);
  IF v_agent_commission > 0 THEN
    INSERT INTO public.agent_commissions_log (agent_id, amount, source_type, related_user_id, transaction_id,
      description, status, commission_rate, transaction_amount, currency)
    VALUES (v_agent.id, v_agent_commission, p_source_type, p_user_id, p_transaction_id,
      'Commission agent ' || v_total_rate || '% des frais sur ' || p_source_type,
      'validated', v_total_rate, ROUND(p_amount, 2), v_currency)
    ON CONFLICT DO NOTHING RETURNING id INTO v_agent_log_id;
    IF v_agent_log_id IS NULL THEN v_agent_duplicate := true; v_agent_commission := 0;
    ELSE
      PERFORM public.credit_agent_wallet_gnf(v_agent.id, v_agent_commission, v_agent_log_id);
      v_any_inserted := true;
      IF v_agent.user_id IS NOT NULL THEN
        BEGIN PERFORM public.create_notification(v_agent.user_id, 'commission_received', 'Commission reçue 💰',
          format('Vous avez reçu une commission de %s GNF.', v_agent_commission),
          jsonb_build_object('amount', v_agent_commission, 'source', p_source_type, 'reference', p_transaction_id, 'role', 'agent_direct'));
        EXCEPTION WHEN OTHERS THEN NULL; END;
      END IF;
    END IF;
  END IF;

  v_total_agent := ROUND(COALESCE(v_agent_commission, 0), 2);
  IF v_total_agent > 0 THEN
    UPDATE public.wallets SET balance = balance - v_total_agent, updated_at = now() WHERE user_id = v_pdg_user_id AND currency = 'GNF';
    BEGIN
      INSERT INTO public.platform_revenue (revenue_type, amount, source_transaction_id, metadata)
      VALUES ('agent_commission_payout', -v_total_agent, p_transaction_id,
              jsonb_build_object('user_id', p_user_id, 'source_type', p_source_type, 'agent_id', v_agent.id));
    EXCEPTION WHEN OTHERS THEN NULL; END;
    IF (v_pdg_balance - v_total_agent) < v_low_threshold THEN
      BEGIN PERFORM public.create_notification(v_pdg_user_id, 'pdg_wallet_low', '⚠️ Solde PDG bas',
        format('Le wallet PDG est bas (%s GNF). Approvisionnez-le pour ne pas bloquer les commissions agents.', ROUND(v_pdg_balance - v_total_agent, 2)),
        jsonb_build_object('balance', ROUND(v_pdg_balance - v_total_agent, 2), 'threshold', v_low_threshold));
      EXCEPTION WHEN OTHERS THEN NULL; END;
    END IF;
  END IF;

  RETURN jsonb_build_object('success', true, 'has_agent', true,
    'already_processed', (NOT v_any_inserted AND v_agent_duplicate),
    'agent_type', COALESCE(v_agent.type_agent, 'principal'), 'agent_id', v_agent.id, 'agent_name', v_agent.name,
    'agent_commission', v_agent_commission, 'agent_rate', v_total_rate,
    'capped_total_rate', v_max_total_rate, 'pdg_debited', v_total_agent, 'total_commissions', v_agent_commission);
END; $cac$;
REVOKE ALL ON FUNCTION public.credit_agent_commission(uuid, numeric, text, uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.credit_agent_commission(uuid, numeric, text, uuid, jsonb) TO service_role;

-- 5) Gardien : 4e check « conversion créditée sans taux tracé » (régression du traçage).
CREATE OR REPLACE FUNCTION public.affiliate_commission_monitor_report()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $mon$
DECLARE v_gap int; v_split int; v_pending int; v_untraced int; v_cap numeric;
BEGIN
  v_cap := public.pdg_setting_numeric('max_total_agent_commission_percentage', 100);

  SELECT count(*) INTO v_gap FROM public.orders o
  JOIN public.vendors v ON v.id = o.vendor_id
  WHERE o.payment_status = 'paid' AND o.created_at >= now() - interval '7 days' AND COALESCE(o.platform_fee_amount, 0) > 0
    AND EXISTS (SELECT 1 FROM public.get_user_agent(v.user_id) ga WHERE ga.agent_id IS NOT NULL)
    AND NOT EXISTS (SELECT 1 FROM public.agent_commissions_log l WHERE l.transaction_id = o.id AND l.source_type = 'achat_produit')
    AND NOT EXISTS (SELECT 1 FROM public.affiliate_commission_pending p WHERE p.source_type = 'achat_produit' AND p.source_ref = o.id::text AND p.status = 'pending');

  SELECT count(*) INTO v_split FROM (
    SELECT l.transaction_id, max(l.transaction_amount) AS fee, sum(l.amount) AS parts
    FROM public.agent_commissions_log l
    WHERE l.created_at >= now() - interval '7 days' AND l.source_type IN ('achat_produit','abonnement')
    GROUP BY l.transaction_id
  ) g WHERE g.fee > 0 AND g.parts > g.fee * v_cap / 100.0;

  SELECT count(*) INTO v_pending FROM public.affiliate_commission_pending
  WHERE status = 'pending' AND created_at < now() - interval '24 hours';

  -- conversion créditée en devise étrangère SANS taux tracé (les nouvelles sont toujours tracées ;
  -- ceci détecte une régression du traçage — jamais les lignes historiques, bornées à 7 j).
  SELECT count(*) INTO v_untraced FROM public.agent_commissions_log l
  WHERE l.created_at >= now() - interval '7 days'
    AND l.credited_currency IS NOT NULL AND l.credited_currency <> 'GNF' AND l.fx_rate IS NULL;

  RETURN jsonb_build_object('generated_at', now(), 'checks', jsonb_build_array(
    jsonb_build_object('key','affiliate_gap','label','Commission affiliation manquante (commande payée, vendeur à agent actif)','severity','high','count',v_gap,'observed',v_gap),
    jsonb_build_object('key','affiliate_split_invalid','label','Répartition affiliation > plafond des frais','severity','critical','count',v_split,'observed',v_split),
    jsonb_build_object('key','affiliate_pending_overdue','label','Commission affiliation en attente > 24 h','severity','high','count',v_pending,'observed',v_pending),
    jsonb_build_object('key','affiliate_untraced_conversion','label','Commission créditée en devise étrangère sans taux tracé','severity','high','count',v_untraced,'observed',v_untraced)
  ));
END; $mon$;
REVOKE ALL ON FUNCTION public.affiliate_commission_monitor_report() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.affiliate_commission_monitor_report() TO service_role;

COMMIT;
