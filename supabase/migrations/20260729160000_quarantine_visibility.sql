-- ============================================================================
-- QUARANTAINE AML — VISIBILITÉ (le plafond ne bouge pas ; on corrige le SILENCE).
-- BLOC 2 : le devis prédit ce qui partira en quarantaine (informer, jamais bloquer).
-- BLOC 3 : le bénéficiaire voit ses fonds en attente (RLS lecture propriétaire) + notifications.
-- Interdits respectés : plafonds/AML inchangés ; release/reject non touchées (branchées ailleurs) ;
-- apply_wallet_cap_split non modifiée (on RÉPLIQUE sa logique en lecture seule pour la prédiction).
-- ============================================================================

-- ── BLOC 2 : prédiction de split plafond (read-only, MÊME calcul qu'apply_wallet_cap_split) ──
CREATE OR REPLACE FUNCTION public.wallet_cap_preview(
  p_user_id uuid, p_current_balance numeric, p_credit numeric, p_currency text)
RETURNS TABLE(available numeric, quarantined numeric, cap_gnf numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_cap numeric; v_bal_gnf numeric; v_credit_gnf numeric; v_over numeric; v_frac numeric; v_q numeric;
BEGIN
  available := COALESCE(p_credit, 0); quarantined := 0; cap_gnf := NULL;
  IF p_credit IS NULL OR p_credit <= 0 THEN RETURN NEXT; RETURN; END IF;
  v_cap := public.wallet_effective_cap(p_user_id);
  cap_gnf := v_cap;
  IF v_cap IS NULL THEN RETURN NEXT; RETURN; END IF;                 -- exempté/PDG → tout dispo
  v_bal_gnf    := public.convert_to_gnf(COALESCE(p_current_balance, 0), p_currency);
  v_credit_gnf := public.convert_to_gnf(p_credit, p_currency);
  v_over := (v_bal_gnf + v_credit_gnf) - v_cap;
  IF v_over <= 0 OR v_credit_gnf <= 0 THEN RETURN NEXT; RETURN; END IF;
  v_frac := LEAST(v_over / v_credit_gnf, 1.0);
  v_q := ROUND(p_credit * v_frac, 2);
  quarantined := v_q; available := p_credit - v_q;
  RETURN NEXT;
END; $$;
REVOKE ALL ON FUNCTION public.wallet_cap_preview(uuid, numeric, numeric, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.wallet_cap_preview(uuid, numeric, numeric, text) TO authenticated, service_role;

-- ── BLOC 2 : wallet_pay_quote enrichi (available_now / quarantined / will_quarantine) ──
CREATE OR REPLACE FUNCTION public.wallet_pay_quote(p_client_user_id uuid, p_qr_reference text, p_amount numeric)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_qr RECORD; v_cfg public.wallet_pay_config; v_owner uuid;
  v_client_cur text; v_client_bal numeric; v_vendor_cur text; v_vendor_bal numeric; v_vendor_id uuid;
  v_debit numeric; v_equiv numeric; v_rate numeric; v_source text;
  v_client_fee numeric; v_total numeric; v_name text;
  v_available numeric; v_quarantined numeric;
BEGIN
  v_cfg := public.wallet_pay_active_config();
  SELECT * INTO v_qr FROM public.vendor_payment_qr WHERE reference = p_qr_reference;
  IF NOT FOUND OR v_qr.status <> 'active' THEN RAISE EXCEPTION 'QR_INVALIDE'; END IF;
  IF v_qr.expires_at IS NOT NULL AND v_qr.expires_at < now() THEN RAISE EXCEPTION 'QR_EXPIRE'; END IF;

  v_owner := COALESCE(v_qr.owner_user_id, (SELECT user_id FROM public.vendors WHERE id = v_qr.vendor_id));
  IF v_owner IS NULL THEN RAISE EXCEPTION 'BENEFICIAIRE_INTROUVABLE'; END IF;

  SELECT balance, currency INTO v_client_bal, v_client_cur FROM public.wallets
    WHERE user_id = p_client_user_id ORDER BY created_at ASC LIMIT 1;
  SELECT balance, currency INTO v_vendor_bal, v_vendor_cur FROM public.wallets
    WHERE user_id = v_owner ORDER BY created_at ASC LIMIT 1;
  IF v_client_cur IS NULL OR v_vendor_cur IS NULL THEN RAISE EXCEPTION 'WALLET_INTROUVABLE'; END IF;

  SELECT business_name INTO v_name FROM public.vendors WHERE id = v_qr.vendor_id;
  IF v_name IS NULL THEN
    SELECT business_name INTO v_name FROM public.professional_services
      WHERE user_id = v_owner AND status = 'active' ORDER BY created_at ASC LIMIT 1;
  END IF;

  IF v_qr.kind = 'dynamic' THEN
    SELECT converted_amount INTO v_debit FROM public.wallet_fx_resolve(v_vendor_cur, v_client_cur, v_qr.amount);
  ELSE
    v_debit := p_amount;
  END IF;
  IF v_debit IS NULL OR v_debit <= 0 THEN RAISE EXCEPTION 'MONTANT_INVALIDE'; END IF;

  SELECT converted_amount, rate_used, rate_source INTO v_equiv, v_rate, v_source
    FROM public.wallet_fx_resolve(v_client_cur, v_vendor_cur, v_debit);

  v_client_fee := round(v_debit * v_cfg.qr_wallet_client_fee_percent / 100.0, 2);
  v_total := v_debit + v_client_fee;

  -- 🟠 PLAFOND AML du bénéficiaire : combien sera DISPONIBLE tout de suite vs MIS EN ATTENTE.
  SELECT available, quarantined INTO v_available, v_quarantined
    FROM public.wallet_cap_preview(v_owner, v_vendor_bal, v_equiv, v_vendor_cur);

  RETURN jsonb_build_object(
    'vendor_name', COALESCE(v_name, 'Bénéficiaire'),
    'kind', v_qr.kind,
    'client_currency', v_client_cur, 'vendor_currency', v_vendor_cur,
    'amount', v_debit, 'equivalent', v_equiv,
    'rate_used', v_rate, 'rate_source', v_source,
    'is_cross_currency', (v_client_cur <> v_vendor_cur),
    'client_fee', v_client_fee, 'client_fee_percent', v_cfg.qr_wallet_client_fee_percent,
    'total_debit', v_total, 'client_balance', v_client_bal,
    'sufficient', (v_client_bal >= v_total),
    -- Plafond bénéficiaire : le payeur voit les DEUX montants avant le PIN.
    'beneficiary_available', v_available,     -- reçu tout de suite
    'beneficiary_quarantined', v_quarantined, -- mis en attente de vérification
    'will_quarantine', (v_quarantined > 0)
  );
END; $function$;
REVOKE ALL ON FUNCTION public.wallet_pay_quote(uuid, text, numeric) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.wallet_pay_quote(uuid, text, numeric) TO authenticated, service_role;

-- ── BLOC 3.2 : RLS — le PROPRIÉTAIRE lit SES propres quarantaines (écriture reste service_role) ──
DROP POLICY IF EXISTS wqf_owner_read ON public.wallet_quarantined_funds;
CREATE POLICY wqf_owner_read ON public.wallet_quarantined_funds
  FOR SELECT TO authenticated USING (user_id = auth.uid());
DROP POLICY IF EXISTS wqf_admin_read ON public.wallet_quarantined_funds;
CREATE POLICY wqf_admin_read ON public.wallet_quarantined_funds
  FOR SELECT TO authenticated USING (public.is_admin_or_pdg());
REVOKE ALL ON public.wallet_quarantined_funds FROM anon;

-- ── BLOC 3.1/3.3 + BLOC 4 : notifications à la mise en quarantaine et à la décision ──
CREATE OR REPLACE FUNCTION public.trg_quarantine_notify()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_pdg uuid; v_amt text;
BEGIN
  v_amt := to_char(NEW.amount, 'FM999G999G999') || ' ' || COALESCE(NEW.currency, 'GNF');

  IF TG_OP = 'INSERT' AND NEW.status = 'pending' THEN
    -- Bénéficiaire : ses fonds sont en attente + parcours KYC.
    INSERT INTO public.notifications (user_id, title, message, type, metadata)
    VALUES (NEW.user_id, 'Fonds en attente de vérification',
      v_amt || ' de votre paiement sont en attente (plafond de compte atteint). Faites vérifier votre compte pour augmenter votre plafond.',
      'warning', jsonb_build_object('kind', 'quarantine_held', 'quarantine_id', NEW.id,
        'amount', NEW.amount, 'currency', NEW.currency, 'link', '/kyc'));
    -- PDG : file d'attente à traiter.
    v_pdg := public.get_pdg_user_id();
    IF v_pdg IS NOT NULL AND v_pdg <> NEW.user_id THEN
      INSERT INTO public.notifications (user_id, title, message, type, metadata)
      VALUES (v_pdg, 'Fonds en quarantaine',
        v_amt || ' en attente de votre décision (plafond bénéficiaire atteint).',
        'warning', jsonb_build_object('kind', 'quarantine_pending_pdg', 'quarantine_id', NEW.id,
          'beneficiary', NEW.user_id, 'amount', NEW.amount, 'currency', NEW.currency, 'link', '/pdg/quarantine'));
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' AND OLD.status = 'pending' AND NEW.status <> OLD.status THEN
    IF NEW.status = 'released' THEN
      INSERT INTO public.notifications (user_id, title, message, type, metadata)
      VALUES (NEW.user_id, 'Fonds ajoutés à votre solde',
        v_amt || ' ont été ajoutés à votre solde après vérification.',
        'success', jsonb_build_object('kind', 'quarantine_released', 'quarantine_id', NEW.id, 'amount', NEW.amount));
    ELSIF NEW.status = 'rejected' THEN
      INSERT INTO public.notifications (user_id, title, message, type, metadata)
      VALUES (NEW.user_id, 'Fonds non validés',
        'Votre demande de ' || v_amt || ' n''a pas été validée. Contactez le support pour en savoir plus.',
        'warning', jsonb_build_object('kind', 'quarantine_rejected', 'quarantine_id', NEW.id, 'amount', NEW.amount));
    END IF;
    RETURN NEW;
  END IF;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '[quarantine notify] % (id %)', SQLERRM, NEW.id;   -- notif best-effort, jamais bloquant
  RETURN NEW;
END; $$;
REVOKE ALL ON FUNCTION public.trg_quarantine_notify() FROM PUBLIC;

DROP TRIGGER IF EXISTS on_quarantine_insert_notify ON public.wallet_quarantined_funds;
CREATE TRIGGER on_quarantine_insert_notify
  AFTER INSERT ON public.wallet_quarantined_funds
  FOR EACH ROW EXECUTE FUNCTION public.trg_quarantine_notify();

DROP TRIGGER IF EXISTS on_quarantine_status_notify ON public.wallet_quarantined_funds;
CREATE TRIGGER on_quarantine_status_notify
  AFTER UPDATE OF status ON public.wallet_quarantined_funds
  FOR EACH ROW EXECUTE FUNCTION public.trg_quarantine_notify();
