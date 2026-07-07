-- ════════════════════════════════════════════════════════════════════════════
-- FIX 9 (Live TikTok) — Cadeaux virtuels (monétisation), version wallet 224
--
-- 1) `live_gift_catalog` : les cadeaux et leurs MONTANTS (config PDG modifiable, pas en dur).
-- 2) `process_live_gift` : RPC ATOMIQUE qui ASSEMBLE les briques argent existantes (aucun
--    nouveau circuit) — débite le donateur (cadeau + commission), crédite le host du montant
--    PLEIN (modèle de commission UNIFIÉ), et alimente le COFFRE PDG de la commission via
--    revenus_pdg (+ trigger credit_pdg_wallet_on_revenue). Idempotence : wallet_transactions
--    .transaction_id UNIQUE + revenus_pdg (source_type, transaction_id).
--
-- Le PAIEMENT réel passe TOUJOURS par cette RPC (service_role, via la route backend). L'effet
-- visuel « gros cadeau » est un broadcast realtime SÉPARÉ et cosmétique — jamais la source de
-- vérité de l'argent.
-- ════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.live_gift_catalog (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code       text NOT NULL UNIQUE,
  emoji      text NOT NULL,
  label      text NOT NULL,
  amount     numeric(12,2) NOT NULL CHECK (amount > 0),
  currency   text NOT NULL DEFAULT 'GNF',
  is_active  boolean NOT NULL DEFAULT true,
  sort_order int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.live_gift_catalog ENABLE ROW LEVEL SECURITY;
-- Lecture publique des cadeaux ACTIFS (le panneau cadeaux côté client). Écriture = service_role
-- uniquement (PDG via backend) : aucune policy INSERT/UPDATE/DELETE → deny par défaut.
DROP POLICY IF EXISTS live_gift_catalog_public_read ON public.live_gift_catalog;
CREATE POLICY live_gift_catalog_public_read ON public.live_gift_catalog FOR SELECT USING (is_active = true);

-- Seed initial — MONTANTS MODIFIABLES ensuite par le PDG (UPDATE amount / is_active).
INSERT INTO public.live_gift_catalog (code, emoji, label, amount, sort_order) VALUES
  ('rose',     '🌹', 'Rose',     1000,   1),
  ('bravo',    '👏', 'Bravo',    2500,   2),
  ('feu',      '🔥', 'Feu',      5000,   3),
  ('diamant',  '💎', 'Diamant',  25000,  4),
  ('couronne', '👑', 'Couronne', 100000, 5)
ON CONFLICT (code) DO NOTHING;

-- ── RPC atomique du cadeau ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.process_live_gift(
  p_donor_id   uuid,
  p_host_id    uuid,
  p_gift_code  text,
  p_amount     numeric,
  p_commission numeric,
  p_live_id    uuid,
  p_currency   text DEFAULT 'GNF'
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cur          text := upper(coalesce(nullif(trim(p_currency), ''), 'GNF'));
  v_donor_wallet public.wallets%ROWTYPE;
  v_total        numeric;
  v_gift_id      uuid := gen_random_uuid();
  v_tx_id        text := 'LGIFT-' || replace(v_gift_id::text, '-', '');
  v_credit       jsonb;
  v_pct          numeric;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'BAD_AMOUNT'; END IF;
  IF p_commission IS NULL OR p_commission < 0 THEN RAISE EXCEPTION 'BAD_FEE'; END IF;
  IF p_donor_id IS NULL OR p_host_id IS NULL THEN RAISE EXCEPTION 'PARTIES_REQUIRED'; END IF;
  IF p_donor_id = p_host_id THEN RAISE EXCEPTION 'SELF_GIFT'; END IF;
  v_total := p_amount + p_commission;

  -- 1) DÉBIT donateur du montant TOTAL (cadeau + commission). Verrou + gardes solde/blocage.
  SELECT * INTO v_donor_wallet FROM public.wallets
    WHERE user_id = p_donor_id AND currency = v_cur ORDER BY id LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DONOR_WALLET_NOT_FOUND'; END IF;
  IF v_donor_wallet.is_blocked THEN RAISE EXCEPTION 'WALLET_BLOCKED'; END IF;
  IF v_donor_wallet.balance < v_total THEN RAISE EXCEPTION 'INSUFFICIENT_FUNDS'; END IF;

  UPDATE public.wallets SET balance = balance - v_total, updated_at = now() WHERE id = v_donor_wallet.id;

  INSERT INTO public.wallet_transactions (
    transaction_id, sender_user_id, receiver_user_id, amount, net_amount,
    transaction_type, status, currency, description, metadata)
  VALUES (
    v_tx_id, p_donor_id, p_host_id, v_total, p_amount,
    'payment', 'completed', v_cur, 'Cadeau live',
    jsonb_build_object('source', 'live_gift', 'live_id', p_live_id, 'gift_code', p_gift_code,
                       'gift_amount', p_amount, 'commission', p_commission));

  -- 2) CRÉDIT host du montant PLEIN (primitive sûre : crée le wallet si absent, idempotente).
  v_credit := public.credit_user_wallet_safe(p_host_id, p_amount, v_cur, 'live_gift', v_tx_id);

  -- 3) COMMISSION → COFFRE PDG (revenus_pdg + trigger). Idempotent par (source_type, transaction_id).
  IF p_commission > 0 THEN
    v_pct := CASE WHEN p_amount > 0 THEN round((p_commission / p_amount) * 100, 2) ELSE 0 END;
    PERFORM public.record_pdg_revenue(
      'autre', p_commission, v_pct, v_gift_id, p_donor_id, NULL,
      jsonb_build_object('source', 'live_gift', 'live_id', p_live_id, 'gift_code', p_gift_code, 'gift_tx', v_tx_id),
      v_cur);
  END IF;

  RETURN jsonb_build_object('success', true, 'transaction_id', v_tx_id,
    'host_credited', COALESCE((v_credit->>'credited')::numeric, 0));
END;
$$;

-- SECURITY DEFINER sensible (mouvement d'argent) → backend service_role uniquement.
REVOKE ALL ON FUNCTION public.process_live_gift(uuid, uuid, text, numeric, numeric, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.process_live_gift(uuid, uuid, text, numeric, numeric, uuid, text) FROM anon;
REVOKE ALL ON FUNCTION public.process_live_gift(uuid, uuid, text, numeric, numeric, uuid, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.process_live_gift(uuid, uuid, text, numeric, numeric, uuid, text) TO service_role;
