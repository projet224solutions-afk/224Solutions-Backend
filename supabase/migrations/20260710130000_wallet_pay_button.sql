-- ============================================================================
-- 💳 BOUTON « PAYER » UNIVERSEL — paiement wallet→vendeur par QR (canal QR wallet).
-- ----------------------------------------------------------------------------
-- RÉUTILISE la fonction transfert CANONIQUE public.execute_atomic_wallet_transfer
-- (appelée par wallet.service.ts:493) — NON dupliquée. Le vendeur reçoit son PRIX PLEIN ;
-- les frais (0 par défaut, stratégie d'adoption) sortent EN PLUS vers le wallet PDG.
-- QR = référence OPAQUE aléatoire stockée serveur (jamais le montant en clair côté client).
-- Les canaux OM/MoMo réutilisent payment_links existant (aucune logique de règlement ici).
-- ============================================================================

-- ── Config frais QR wallet (versionnée, sœur de agent_cash_config) ──
CREATE TABLE IF NOT EXISTS public.wallet_pay_config (
  id                            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  qr_wallet_client_fee_percent  numeric NOT NULL DEFAULT 0 CHECK (qr_wallet_client_fee_percent >= 0),
  qr_wallet_vendor_fee_percent  numeric NOT NULL DEFAULT 0 CHECK (qr_wallet_vendor_fee_percent >= 0),
  is_active                     boolean NOT NULL DEFAULT true,
  created_at                    timestamptz NOT NULL DEFAULT now(),
  created_by                    uuid
);
ALTER TABLE public.wallet_pay_config ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS wpc_pdg_read  ON public.wallet_pay_config;
DROP POLICY IF EXISTS wpc_pdg_write ON public.wallet_pay_config;
CREATE POLICY wpc_pdg_read  ON public.wallet_pay_config FOR SELECT TO authenticated USING (public.is_admin_or_pdg());
CREATE POLICY wpc_pdg_write ON public.wallet_pay_config FOR ALL    TO authenticated USING (public.is_admin_or_pdg()) WITH CHECK (public.is_admin_or_pdg());
REVOKE ALL ON public.wallet_pay_config FROM anon;
CREATE UNIQUE INDEX IF NOT EXISTS uq_wallet_pay_config_active ON public.wallet_pay_config (is_active) WHERE is_active = true;
INSERT INTO public.wallet_pay_config (is_active) SELECT true WHERE NOT EXISTS (SELECT 1 FROM public.wallet_pay_config WHERE is_active = true);

CREATE OR REPLACE FUNCTION public.wallet_pay_active_config()
RETURNS public.wallet_pay_config LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT * FROM public.wallet_pay_config WHERE is_active = true ORDER BY created_at DESC LIMIT 1;
$$;
REVOKE ALL ON FUNCTION public.wallet_pay_active_config() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.wallet_pay_active_config() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.wallet_pay_config_update(p_changes jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_cur public.wallet_pay_config; v_id uuid;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  v_cur := public.wallet_pay_active_config();
  UPDATE public.wallet_pay_config SET is_active = false WHERE is_active = true;
  INSERT INTO public.wallet_pay_config (qr_wallet_client_fee_percent, qr_wallet_vendor_fee_percent, is_active, created_by)
  VALUES (
    COALESCE((p_changes->>'qr_wallet_client_fee_percent')::numeric, v_cur.qr_wallet_client_fee_percent),
    COALESCE((p_changes->>'qr_wallet_vendor_fee_percent')::numeric, v_cur.qr_wallet_vendor_fee_percent),
    true, auth.uid()) RETURNING id INTO v_id;
  RETURN jsonb_build_object('success', true, 'config_id', v_id);
END $$;
REVOKE ALL ON FUNCTION public.wallet_pay_config_update(jsonb) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.wallet_pay_config_update(jsonb) TO authenticated, service_role;

-- ── QR de paiement vendeur (statique = comptoir permanent ; dynamic = montant + TTL) ──
CREATE TABLE IF NOT EXISTS public.vendor_payment_qr (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id   uuid NOT NULL,
  kind        text NOT NULL DEFAULT 'static' CHECK (kind IN ('static','dynamic')),
  amount      numeric,                         -- imposé si dynamic
  reference   text UNIQUE NOT NULL,            -- token OPAQUE aléatoire (le QR encode ceci)
  status      text NOT NULL DEFAULT 'active' CHECK (status IN ('active','used','expired')),
  expires_at  timestamptz,                     -- NULL pour static
  created_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.vendor_payment_qr ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS vpq_admin_read ON public.vendor_payment_qr;
CREATE POLICY vpq_admin_read ON public.vendor_payment_qr FOR SELECT TO authenticated USING (public.is_admin_or_pdg());
REVOKE ALL ON public.vendor_payment_qr FROM anon;
CREATE INDEX IF NOT EXISTS ix_vpq_vendor ON public.vendor_payment_qr (vendor_id, status);

-- ── Ledger léger des paiements wallet (trace ; enhanced_transactions garde le détail transfert) ──
CREATE TABLE IF NOT EXISTS public.wallet_pay_ledger (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  parent_tx_id   uuid NOT NULL,
  leg            text NOT NULL CHECK (leg IN ('client_debit_vendor','vendor_credit','client_fee_pdg','vendor_fee_pdg')),
  client_user_id uuid, vendor_id uuid, amount numeric NOT NULL, currency text NOT NULL DEFAULT 'GNF',
  created_at     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.wallet_pay_ledger ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS wpl_admin_read ON public.wallet_pay_ledger;
CREATE POLICY wpl_admin_read ON public.wallet_pay_ledger FOR SELECT TO authenticated USING (public.is_admin_or_pdg());
REVOKE UPDATE, DELETE ON public.wallet_pay_ledger FROM PUBLIC, anon, authenticated, service_role;

-- ── En-tête idempotence des paiements ──
CREATE TABLE IF NOT EXISTS public.wallet_pay_operations (
  parent_tx_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  idempotency_key text UNIQUE NOT NULL,
  client_user_id uuid, vendor_id uuid, amount numeric, fee numeric DEFAULT 0,
  result jsonb, created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.wallet_pay_operations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS wpo_admin_read ON public.wallet_pay_operations;
CREATE POLICY wpo_admin_read ON public.wallet_pay_operations FOR SELECT TO authenticated USING (public.is_admin_or_pdg());
REVOKE ALL ON public.wallet_pay_operations FROM anon;

-- Realtime : le vendeur voit le paiement en direct (« le ding »).
DO $$ BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.wallet_pay_ledger;
EXCEPTION WHEN duplicate_object OR undefined_object THEN NULL; END $$;

-- ── RPC : paiement wallet → vendeur (réutilise le transfert canonique) ──
CREATE OR REPLACE FUNCTION public.pay_vendor_via_wallet(
  p_client_user_id uuid, p_qr_reference text, p_amount numeric, p_idempotency_key text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_parent uuid; v_qr RECORD; v_cfg public.wallet_pay_config;
  v_vendor RECORD; v_vendor_user uuid; v_amount numeric;
  v_client_wallet bigint; v_client_bal numeric; v_vendor_wallet bigint; v_vendor_bal numeric;
  v_pdg_wallet bigint; v_client_fee numeric := 0; v_vendor_fee numeric := 0; v_tr jsonb;
BEGIN
  IF p_client_user_id IS NULL THEN RAISE EXCEPTION 'CLIENT_INTROUVABLE'; END IF;
  v_cfg := public.wallet_pay_active_config();

  INSERT INTO public.wallet_pay_operations (idempotency_key, client_user_id, amount)
  VALUES (p_idempotency_key, p_client_user_id, p_amount)
  ON CONFLICT (idempotency_key) DO NOTHING RETURNING parent_tx_id INTO v_parent;
  IF v_parent IS NULL THEN
    RETURN (SELECT result FROM public.wallet_pay_operations WHERE idempotency_key = p_idempotency_key);
  END IF;

  -- Valider le QR (référence opaque, statut, TTL). Verrou pour empêcher le double-usage.
  SELECT * INTO v_qr FROM public.vendor_payment_qr WHERE reference = p_qr_reference FOR UPDATE;
  IF NOT FOUND OR v_qr.status <> 'active' THEN RAISE EXCEPTION 'QR_INVALIDE'; END IF;
  IF v_qr.expires_at IS NOT NULL AND v_qr.expires_at < now() THEN
    UPDATE public.vendor_payment_qr SET status='expired' WHERE id = v_qr.id;
    RAISE EXCEPTION 'QR_EXPIRE';
  END IF;

  -- Montant : imposé si dynamic, sinon fourni par le client.
  v_amount := COALESCE(v_qr.amount, p_amount);
  IF v_amount IS NULL OR v_amount <= 0 THEN RAISE EXCEPTION 'MONTANT_INVALIDE'; END IF;

  SELECT id, user_id INTO v_vendor FROM public.vendors WHERE id = v_qr.vendor_id;
  v_vendor_user := v_vendor.user_id;
  IF v_vendor_user IS NULL THEN RAISE EXCEPTION 'VENDEUR_INTROUVABLE'; END IF;

  SELECT id, balance INTO v_client_wallet, v_client_bal FROM public.wallets WHERE user_id = p_client_user_id AND currency = 'GNF';
  SELECT id, balance INTO v_vendor_wallet, v_vendor_bal FROM public.wallets WHERE user_id = v_vendor_user AND currency = 'GNF';
  IF v_client_wallet IS NULL OR v_vendor_wallet IS NULL THEN RAISE EXCEPTION 'WALLET_INTROUVABLE'; END IF;

  v_client_fee := round(v_amount * v_cfg.qr_wallet_client_fee_percent / 100.0, 2);
  v_vendor_fee := round(v_amount * v_cfg.qr_wallet_vendor_fee_percent / 100.0, 2);

  -- 1) Paiement principal : transfert CANONIQUE client → vendeur (prix plein). Atomique dans CE bloc.
  v_tr := public.execute_atomic_wallet_transfer(
    p_client_user_id, v_vendor_user, v_amount, 'wallet_pay:' || v_parent::text,
    v_client_wallet, v_vendor_wallet, v_client_bal, v_vendor_bal);
  IF NOT COALESCE((v_tr->>'success')::boolean, false) THEN RAISE EXCEPTION 'TRANSFERT_ECHOUE'; END IF;
  INSERT INTO public.wallet_pay_ledger (parent_tx_id, leg, client_user_id, vendor_id, amount)
  VALUES (v_parent, 'client_debit_vendor', p_client_user_id, v_qr.vendor_id, v_amount),
         (v_parent, 'vendor_credit', p_client_user_id, v_qr.vendor_id, v_amount);

  v_pdg_wallet := public.get_pdg_gnf_wallet_id();

  -- 2) Frais client (0 par défaut) → PDG, EN PLUS (débit direct verrouillé).
  IF v_client_fee > 0 AND v_pdg_wallet IS NOT NULL THEN
    PERFORM public._acash_debit_wallet(v_client_wallet, v_client_fee, 'SOLDE_INSUFFISANT');
    UPDATE public.wallets SET balance = balance + v_client_fee, updated_at = now() WHERE id = v_pdg_wallet;
    INSERT INTO public.wallet_pay_ledger (parent_tx_id, leg, client_user_id, vendor_id, amount)
    VALUES (v_parent, 'client_fee_pdg', p_client_user_id, v_qr.vendor_id, v_client_fee);
  END IF;

  -- 3) Frais vendeur (0 par défaut) → PDG, prélevés sur le vendeur.
  IF v_vendor_fee > 0 AND v_pdg_wallet IS NOT NULL THEN
    PERFORM public._acash_debit_wallet(v_vendor_wallet, v_vendor_fee, 'SOLDE_INSUFFISANT');
    UPDATE public.wallets SET balance = balance + v_vendor_fee, updated_at = now() WHERE id = v_pdg_wallet;
    INSERT INTO public.wallet_pay_ledger (parent_tx_id, leg, client_user_id, vendor_id, amount)
    VALUES (v_parent, 'vendor_fee_pdg', p_client_user_id, v_qr.vendor_id, v_vendor_fee);
  END IF;

  -- QR dynamic à usage unique.
  IF v_qr.kind = 'dynamic' THEN UPDATE public.vendor_payment_qr SET status='used' WHERE id = v_qr.id; END IF;

  UPDATE public.wallet_pay_operations SET vendor_id = v_qr.vendor_id, amount = v_amount, fee = v_client_fee + v_vendor_fee,
    result = jsonb_build_object('success', true, 'parent_tx_id', v_parent, 'amount', v_amount,
      'client_fee', v_client_fee, 'vendor_fee', v_vendor_fee, 'transaction_id', v_tr->>'transaction_id')
  WHERE parent_tx_id = v_parent;
  RETURN (SELECT result FROM public.wallet_pay_operations WHERE parent_tx_id = v_parent);
END $$;
REVOKE ALL ON FUNCTION public.pay_vendor_via_wallet(uuid, text, numeric, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.pay_vendor_via_wallet(uuid, text, numeric, text) TO service_role;

SELECT 'Bouton Payer wallet installé : config frais + vendor_payment_qr + pay_vendor_via_wallet (transfert canonique réutilisé).' AS status;
