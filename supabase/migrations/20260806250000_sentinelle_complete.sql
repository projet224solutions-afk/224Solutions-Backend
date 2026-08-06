-- ═══════════════════════════════════════════════════════════════════════════
-- SENTINELLE COMPLÈTE + gardien cash. Migrations NOUVELLES.
-- CH1.5 : gardien commission surveille AUSSI les commandes CASH payées.
-- CH2A  : auto-résolution des anomalies fatome quand le gap repasse à 0.
-- CH2B  : triggers Étage A sur wallet_transactions + revenus_pdg + transferts FX (enhanced_transactions).
--         Tous NON-bloquants (EXCEPTION WHEN OTHERS → RETURN NULL), ligne seule, lookups indexés.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── CH1.5 — commission_monitor_report : + commandes CASH payées ─────────────
CREATE OR REPLACE FUNCTION public.commission_monitor_report()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_gap int; v_badrate int; v_nonpos int; v_gap_nonwallet int; v_fee_pct numeric;
BEGIN
  SELECT count(*) INTO v_gap FROM public.wallet_transactions wt
  WHERE wt.transaction_type = 'commission'
    AND wt.metadata->>'source' = 'buyer_commission'
    AND wt.created_at > now() - interval '7 days'
    AND wt.metadata->>'order_id' IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM public.revenus_pdg r WHERE r.metadata->>'order_id' = wt.metadata->>'order_id');

  SELECT COALESCE((SELECT setting_value::numeric FROM public.system_settings WHERE setting_key = 'purchase_fee_percent'), 0)
    INTO v_fee_pct;
  IF v_fee_pct > 0 THEN
    -- NON-wallet PAYÉES (carte, mobile money ET cash) sans revenu 'frais_achat_commande'.
    SELECT count(*) INTO v_gap_nonwallet FROM public.orders o
    WHERE o.payment_status = 'paid'
      AND o.payment_method::text IN ('card', 'mobile_money', 'cash')
      AND o.created_at > now() - interval '7 days'
      AND NOT EXISTS (SELECT 1 FROM public.revenus_pdg r
        WHERE r.source_type = 'frais_achat_commande' AND r.metadata->>'order_id' = o.id::text)
      AND NOT EXISTS (SELECT 1 FROM public.revenus_pdg r
        WHERE r.source_type = 'frais_achat_marketplace' AND r.metadata->>'order_id' = o.id::text);
  ELSE
    v_gap_nonwallet := 0;
  END IF;

  SELECT count(*) INTO v_badrate FROM public.agents_management
  WHERE is_active = true AND (
       COALESCE(commission_rate, 0) < 0 OR COALESCE(commission_rate, 0) > 100
    OR COALESCE(commission_agent_principal, 0) < 0 OR COALESCE(commission_agent_principal, 0) > 100
    OR COALESCE(commission_sous_agent, 0) < 0 OR COALESCE(commission_sous_agent, 0) > 100);

  SELECT count(*) INTO v_nonpos FROM public.revenus_pdg
  WHERE COALESCE(amount, 0) <= 0 AND created_at > now() - interval '7 days';

  RETURN jsonb_build_object('generated_at', now(), 'checks', jsonb_build_array(
    jsonb_build_object('key','commission_revenue_gap','label','Commission acheteur (wallet) prélevée mais non enregistrée (revenus PDG)','severity','high','count',v_gap,'observed',v_gap),
    jsonb_build_object('key','commission_revenue_gap_nonwallet','label','Commande carte/mobile/cash payée sans revenu commission (revenus PDG)','severity','high','count',v_gap_nonwallet,'observed',v_gap_nonwallet),
    jsonb_build_object('key','agent_bad_rate','label','Taux de commission agent hors limites (0–100%)','severity','medium','count',v_badrate,'observed',v_badrate),
    jsonb_build_object('key','revenue_nonpositive','label','Revenu PDG nul ou négatif','severity','medium','count',v_nonpos,'observed',v_nonpos)
  ));
END;
$$;
REVOKE ALL ON FUNCTION public.commission_monitor_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.commission_monitor_report() TO service_role;

-- ── CH2A — auto-résolution : marquer resolved les anomalies d'un type quand plus d'écart ──
CREATE OR REPLACE FUNCTION public.fatome_resolve_type(p_type text)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_n int;
BEGIN
  UPDATE public.fatome_anomalies SET resolved = true
  WHERE anomaly_type = p_type AND resolved = false;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public.fatome_resolve_type(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fatome_resolve_type(text) TO service_role;

-- ── CH2B — Étage A : wallet_transactions ────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fatome_check_wallet_tx()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- Montant ≤ 0 (backstop : la contrainte CHECK amount>0 le bloque déjà ; le trigger reste
  -- une défense supplémentaire si la contrainte venait à disparaître). S'applique à tout type.
  IF COALESCE(NEW.amount, 0) <= 0 THEN
    PERFORM public.fatome_raise('wallet_amount_nonpositive', NEW.id::text, 'high',
      jsonb_build_object('type', NEW.transaction_type::text, 'amount', NEW.amount, 'currency', NEW.currency));
  END IF;
  -- Devise INCONNUE (absente de currencies ET de la liste zéro-décimale).
  IF NEW.currency IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.currencies c WHERE upper(c.code) = upper(NEW.currency))
     AND upper(NEW.currency) <> ALL (ARRAY['GNF','XOF','XAF','BIF','DJF','KMF','MGA','RWF','UGX','CLP','JPY','KRW','PYG','VND','VUV','XPF']) THEN
    PERFORM public.fatome_raise('wallet_currency_unknown', NEW.id::text, 'medium',
      jsonb_build_object('currency', NEW.currency, 'amount', NEW.amount));
  END IF;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS trg_fatome_wallet_tx ON public.wallet_transactions;
CREATE TRIGGER trg_fatome_wallet_tx AFTER INSERT ON public.wallet_transactions
  FOR EACH ROW EXECUTE FUNCTION public.fatome_check_wallet_tx();

-- ── CH2B — Étage A : revenus_pdg ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fatome_check_revenus_pdg()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF COALESCE(NEW.amount, 0) <= 0 THEN
    PERFORM public.fatome_raise('revenue_nonpositive', COALESCE(NEW.transaction_id::text, NEW.id::text), 'high',
      jsonb_build_object('source_type', NEW.source_type, 'amount', NEW.amount));
  END IF;
  -- source_type hors nomenclature connue.
  IF NEW.source_type IS NOT NULL AND NEW.source_type <> ALL (ARRAY[
    'frais_transaction_wallet','frais_achat_commande','frais_achat_marketplace','frais_abonnement',
    'abonnement_vendeur','abonnement_service','abonnement_chauffeur','frais_retrait','frais_paiement_lien',
    'event_ticket_commission','fx_spread','autre']) THEN
    PERFORM public.fatome_raise('revenue_source_unknown', COALESCE(NEW.transaction_id::text, NEW.id::text), 'medium',
      jsonb_build_object('source_type', NEW.source_type, 'amount', NEW.amount));
  END IF;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS trg_fatome_revenus_pdg ON public.revenus_pdg;
CREATE TRIGGER trg_fatome_revenus_pdg AFTER INSERT ON public.revenus_pdg
  FOR EACH ROW EXECUTE FUNCTION public.fatome_check_revenus_pdg();

-- ── CH2B — Étage A : transferts FX (enhanced_transactions, lignes fx) ───────
CREATE OR REPLACE FUNCTION public.fatome_check_fx_transfer()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rate numeric; v_credit numeric; v_src text; v_dst text; v_tol numeric;
BEGIN
  IF COALESCE(NEW.metadata->>'fx', 'false') <> 'true' THEN RETURN NULL; END IF;
  v_rate := (NEW.metadata->>'rate_used')::numeric;
  -- Taux absent sur un transfert marqué FX.
  IF v_rate IS NULL OR v_rate <= 0 THEN
    PERFORM public.fatome_raise('fx_transfer_no_rate', NEW.id::text, 'high',
      jsonb_build_object('metadata', NEW.metadata));
    RETURN NULL;
  END IF;
  -- Conservation ligne : montant crédité ≈ montant × taux (à la précision de la devise cible).
  v_credit := (NEW.metadata->>'credit_amount')::numeric;
  v_dst := NEW.metadata->>'receiver_currency';
  IF v_credit IS NOT NULL AND NEW.amount IS NOT NULL AND v_dst IS NOT NULL THEN
    v_tol := power(10, -public._ccy_decimals(v_dst)); -- 1 unité de la plus petite décimale
    IF abs(v_credit - round(NEW.amount * v_rate, public._ccy_decimals(v_dst))) > v_tol THEN
      PERFORM public.fatome_raise('fx_transfer_conservation', NEW.id::text, 'critical',
        jsonb_build_object('amount', NEW.amount, 'rate', v_rate, 'credit', v_credit, 'to', v_dst));
    END IF;
  END IF;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS trg_fatome_fx_transfer ON public.enhanced_transactions;
CREATE TRIGGER trg_fatome_fx_transfer AFTER INSERT ON public.enhanced_transactions
  FOR EACH ROW EXECUTE FUNCTION public.fatome_check_fx_transfer();
