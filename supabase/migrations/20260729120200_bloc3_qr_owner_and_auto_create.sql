-- ============================================================================
-- BLOC 3 — QR OBLIGATOIREMENT lié au wallet + créé AUTOMATIQUEMENT (vendeurs ET prestataires).
-- ----------------------------------------------------------------------------
-- • Liaison QR→wallet gravée dans le schéma : owner_user_id NOT NULL (le QR = face publique du
--   wallet du propriétaire ; la devise n'est PAS stockée dans le QR → rien à désynchroniser,
--   résolue au paiement par owner_user_id).
-- • vendor_id devient nullable (un prestataire n'a pas de vendor) ; cohérent si présent.
-- • Trigger AFTER INSERT sur vendors ET professional_services → token statique créé d'office.
-- • Backfill de tous les encaisseurs existants sans QR.
-- ============================================================================

-- 1) Schéma : owner_user_id (liaison wallet), vendor_id nullable.
ALTER TABLE public.vendor_payment_qr ADD COLUMN IF NOT EXISTS owner_user_id uuid;

UPDATE public.vendor_payment_qr q
   SET owner_user_id = v.user_id
  FROM public.vendors v
 WHERE q.vendor_id = v.id AND q.owner_user_id IS NULL;

ALTER TABLE public.vendor_payment_qr ALTER COLUMN vendor_id DROP NOT NULL;
-- owner_user_id NOT NULL seulement si le backfill ci-dessus n'a laissé aucun trou.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.vendor_payment_qr WHERE owner_user_id IS NULL) THEN
    ALTER TABLE public.vendor_payment_qr ALTER COLUMN owner_user_id SET NOT NULL;
  ELSE
    RAISE WARNING 'vendor_payment_qr : lignes sans owner_user_id — NOT NULL non posé (à investiguer)';
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS ix_vpq_owner ON public.vendor_payment_qr (owner_user_id, status);

-- 2) Générateur idempotent du token statique (UN QR actif par propriétaire).
-- Réutilise le token opaque 24 octets base64url (identique au générateur applicatif). Le QR ne porte
-- QUE le token — aucune devise, aucun montant (interdit).
CREATE OR REPLACE FUNCTION public.vendor_payment_qr_ensure(p_owner_user_id uuid, p_vendor_id uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_ref text;
BEGIN
  IF p_owner_user_id IS NULL THEN RETURN NULL; END IF;
  SELECT reference INTO v_ref FROM public.vendor_payment_qr
   WHERE owner_user_id = p_owner_user_id AND kind = 'static' AND status = 'active' LIMIT 1;
  IF v_ref IS NOT NULL THEN RETURN v_ref; END IF;
  v_ref := translate(encode(gen_random_bytes(24), 'base64'), '+/=', '-_');
  INSERT INTO public.vendor_payment_qr (owner_user_id, vendor_id, kind, reference)
  VALUES (p_owner_user_id, p_vendor_id, 'static', v_ref);
  RETURN v_ref;
END;
$$;
REVOKE ALL ON FUNCTION public.vendor_payment_qr_ensure(uuid, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.vendor_payment_qr_ensure(uuid, uuid) TO authenticated, service_role;

-- 3) Triggers AFTER INSERT — la garantie vit en base (comme le filet pays), quelle que soit la
--    porte d'entrée applicative.
CREATE OR REPLACE FUNCTION public.trg_vendor_qr_autocreate()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM public.vendor_payment_qr_ensure(NEW.user_id, NEW.id);   -- vendeur : vendor_id = NEW.id
  RETURN NEW;
END; $$;
REVOKE ALL ON FUNCTION public.trg_vendor_qr_autocreate() FROM PUBLIC;
DROP TRIGGER IF EXISTS on_vendor_created_qr ON public.vendors;
CREATE TRIGGER on_vendor_created_qr
  AFTER INSERT ON public.vendors
  FOR EACH ROW EXECUTE FUNCTION public.trg_vendor_qr_autocreate();

CREATE OR REPLACE FUNCTION public.trg_provider_qr_autocreate()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM public.vendor_payment_qr_ensure(NEW.user_id, NULL);     -- prestataire : pas de vendor_id
  RETURN NEW;
END; $$;
REVOKE ALL ON FUNCTION public.trg_provider_qr_autocreate() FROM PUBLIC;
DROP TRIGGER IF EXISTS on_provider_created_qr ON public.professional_services;
CREATE TRIGGER on_provider_created_qr
  AFTER INSERT ON public.professional_services
  FOR EACH ROW EXECUTE FUNCTION public.trg_provider_qr_autocreate();

-- 4) Backfill : QR pour tous les vendeurs et prestataires existants qui n'en ont pas (par owner).
DO $$
DECLARE v_vend int := 0; v_prov int := 0;
BEGIN
  SELECT count(*) INTO v_vend FROM (
    SELECT public.vendor_payment_qr_ensure(v.user_id, v.id)
    FROM public.vendors v
    WHERE v.user_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM public.vendor_payment_qr q
                      WHERE q.owner_user_id = v.user_id AND q.kind='static' AND q.status='active')
  ) s;
  SELECT count(*) INTO v_prov FROM (
    SELECT public.vendor_payment_qr_ensure(ps.user_id, NULL)
    FROM (SELECT DISTINCT user_id FROM public.professional_services WHERE user_id IS NOT NULL) ps
    WHERE NOT EXISTS (SELECT 1 FROM public.vendor_payment_qr q
                      WHERE q.owner_user_id = ps.user_id AND q.kind='static' AND q.status='active')
  ) s;
  RAISE NOTICE 'BLOC3 backfill QR : % vendeur(s), % prestataire(s) créés', v_vend, v_prov;
END $$;

-- 5) pay_vendor_via_wallet : bénéficiaire résolu par owner_user_id (source de vérité), repli vendor_id.
--    (Ré-installe la fonction du BLOC 2 en changeant UNIQUEMENT la résolution du bénéficiaire.)
CREATE OR REPLACE FUNCTION public.pay_vendor_via_wallet(
  p_client_user_id uuid, p_qr_reference text, p_amount numeric, p_idempotency_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_parent uuid; v_qr RECORD; v_cfg public.wallet_pay_config; v_vendor_user uuid;
  v_client_wallet bigint; v_client_bal numeric; v_client_cur text;
  v_vendor_wallet bigint; v_vendor_bal numeric; v_vendor_cur text;
  v_debit numeric; v_credit numeric;
  v_client_fee numeric := 0; v_vendor_fee numeric := 0;
  v_pdg_client bigint; v_pdg_vendor bigint; v_tr jsonb;
BEGIN
  IF p_client_user_id IS NULL THEN RAISE EXCEPTION 'CLIENT_INTROUVABLE'; END IF;
  v_cfg := public.wallet_pay_active_config();

  INSERT INTO public.wallet_pay_operations (idempotency_key, client_user_id, amount)
  VALUES (p_idempotency_key, p_client_user_id, p_amount)
  ON CONFLICT (idempotency_key) DO NOTHING RETURNING parent_tx_id INTO v_parent;
  IF v_parent IS NULL THEN
    RETURN (SELECT result FROM public.wallet_pay_operations WHERE idempotency_key = p_idempotency_key);
  END IF;

  SELECT * INTO v_qr FROM public.vendor_payment_qr WHERE reference = p_qr_reference FOR UPDATE;
  IF NOT FOUND OR v_qr.status <> 'active' THEN RAISE EXCEPTION 'QR_INVALIDE'; END IF;
  IF v_qr.expires_at IS NOT NULL AND v_qr.expires_at < now() THEN
    UPDATE public.vendor_payment_qr SET status='expired' WHERE id = v_qr.id;
    RAISE EXCEPTION 'QR_EXPIRE';
  END IF;

  -- Bénéficiaire = propriétaire du QR (owner_user_id). Repli vendor_id (QR legacy sans owner).
  v_vendor_user := COALESCE(v_qr.owner_user_id, (SELECT user_id FROM public.vendors WHERE id = v_qr.vendor_id));
  IF v_vendor_user IS NULL THEN RAISE EXCEPTION 'BENEFICIAIRE_INTROUVABLE'; END IF;

  SELECT id, balance, currency INTO v_client_wallet, v_client_bal, v_client_cur
    FROM public.wallets WHERE user_id = p_client_user_id ORDER BY created_at ASC LIMIT 1;
  SELECT id, balance, currency INTO v_vendor_wallet, v_vendor_bal, v_vendor_cur
    FROM public.wallets WHERE user_id = v_vendor_user ORDER BY created_at ASC LIMIT 1;
  IF v_client_wallet IS NULL OR v_vendor_wallet IS NULL THEN RAISE EXCEPTION 'WALLET_INTROUVABLE'; END IF;

  IF v_qr.kind = 'dynamic' THEN
    IF v_qr.amount IS NULL OR v_qr.amount <= 0 THEN RAISE EXCEPTION 'MONTANT_INVALIDE'; END IF;
    SELECT converted_amount INTO v_debit FROM public.wallet_fx_resolve(v_vendor_cur, v_client_cur, v_qr.amount);
  ELSE
    v_debit := p_amount;
  END IF;
  IF v_debit IS NULL OR v_debit <= 0 THEN RAISE EXCEPTION 'MONTANT_INVALIDE'; END IF;

  v_tr := public.execute_atomic_wallet_transfer(
    p_client_user_id, v_vendor_user, v_debit, 'wallet_pay:' || v_parent::text,
    v_client_wallet, v_vendor_wallet, v_client_bal, v_vendor_bal);
  IF NOT COALESCE((v_tr->>'success')::boolean, false) THEN RAISE EXCEPTION 'TRANSFERT_ECHOUE'; END IF;
  v_credit := COALESCE((v_tr->>'credit_amount')::numeric, v_debit);

  INSERT INTO public.wallet_pay_ledger (parent_tx_id, leg, client_user_id, vendor_id, amount, currency)
  VALUES (v_parent, 'client_debit_vendor', p_client_user_id, v_qr.vendor_id, v_debit,  v_client_cur),
         (v_parent, 'vendor_credit',       p_client_user_id, v_qr.vendor_id, v_credit, v_vendor_cur);

  v_client_fee := round(v_debit * v_cfg.qr_wallet_client_fee_percent / 100.0, 2);
  IF v_client_fee > 0 THEN
    v_pdg_client := public.get_pdg_wallet_id(v_client_cur);
    IF v_pdg_client IS NULL THEN
      PERFORM public.wallet_pay_alert_missing_pdg(v_client_cur, v_parent, v_client_fee);
    ELSE
      PERFORM public._acash_debit_wallet(v_client_wallet, v_client_fee, 'SOLDE_INSUFFISANT');
      UPDATE public.wallets SET balance = balance + v_client_fee, updated_at = now() WHERE id = v_pdg_client;
      INSERT INTO public.wallet_pay_ledger (parent_tx_id, leg, client_user_id, vendor_id, amount, currency)
      VALUES (v_parent, 'client_fee_pdg', p_client_user_id, v_qr.vendor_id, v_client_fee, v_client_cur);
    END IF;
  END IF;

  v_vendor_fee := round(v_credit * v_cfg.qr_wallet_vendor_fee_percent / 100.0, 2);
  IF v_vendor_fee > 0 THEN
    v_pdg_vendor := public.get_pdg_wallet_id(v_vendor_cur);
    IF v_pdg_vendor IS NULL THEN
      PERFORM public.wallet_pay_alert_missing_pdg(v_vendor_cur, v_parent, v_vendor_fee);
    ELSE
      PERFORM public._acash_debit_wallet(v_vendor_wallet, v_vendor_fee, 'SOLDE_INSUFFISANT');
      UPDATE public.wallets SET balance = balance + v_vendor_fee, updated_at = now() WHERE id = v_pdg_vendor;
      INSERT INTO public.wallet_pay_ledger (parent_tx_id, leg, client_user_id, vendor_id, amount, currency)
      VALUES (v_parent, 'vendor_fee_pdg', p_client_user_id, v_qr.vendor_id, v_vendor_fee, v_vendor_cur);
    END IF;
  END IF;

  IF v_qr.kind = 'dynamic' THEN UPDATE public.vendor_payment_qr SET status='used' WHERE id = v_qr.id; END IF;

  UPDATE public.wallet_pay_operations SET vendor_id = v_qr.vendor_id, amount = v_debit, fee = v_client_fee + v_vendor_fee,
    result = jsonb_build_object('success', true, 'parent_tx_id', v_parent,
      'amount', v_debit, 'client_currency', v_client_cur, 'credit_amount', v_credit, 'vendor_currency', v_vendor_cur,
      'client_fee', v_client_fee, 'vendor_fee', v_vendor_fee, 'transaction_id', v_tr->>'transaction_id')
  WHERE parent_tx_id = v_parent;
  RETURN (SELECT result FROM public.wallet_pay_operations WHERE parent_tx_id = v_parent);
END $function$;
REVOKE ALL ON FUNCTION public.pay_vendor_via_wallet(uuid,text,numeric,text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.pay_vendor_via_wallet(uuid,text,numeric,text) TO service_role;
