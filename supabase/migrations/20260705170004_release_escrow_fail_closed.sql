-- ============================================================================
-- 🛡️ CORRECTIF (fail-closed) : release_escrow_to_seller ne doit JAMAIS marquer
--    l'escrow 'released' si le crédit vendeur n'a pas eu lieu.
-- ----------------------------------------------------------------------------
-- BUG (audit 2026-07-05) : la primitive de libération (utilisée aussi par les liens
-- escrow via confirm_delivery_and_release_escrow et l'auto-release J+14) créditait
-- le vendeur via credit_user_wallet_safe PUIS marquait l'escrow 'released' SANS
-- vérifier que le crédit avait réellement eu lieu. refund_order_escrow, lui, a cette
-- garde. Si credit_user_wallet_safe renvoyait 0 (sans skip idempotent), l'escrow
-- passait 'released' sans que le vendeur soit payé.
--
-- FIX : recrée release_escrow_to_seller À L'IDENTIQUE de 20260704140000 (SANS repli
-- 2,5 %) + garde fail-closed : si le crédit n'était PAS un skip idempotent et n'a
-- rien crédité/quarantiné → RAISE (rollback), jamais un 'released' sans paiement.
-- Idempotent (CREATE OR REPLACE). Grants inchangés (service_role uniquement).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.release_escrow_to_seller(
  p_escrow_id uuid,
  p_reason    text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_escrow        RECORD;
  v_commission    numeric;
  v_vendor_amount numeric;
  v_cur           text;
  v_seller        uuid;
  v_pdg           uuid;
  v_seller_res    jsonb;
  v_wallet_id     bigint;
  v_got           numeric;
BEGIN
  SELECT * INTO v_escrow FROM public.escrow_transactions WHERE id = p_escrow_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Escrow introuvable');
  END IF;
  IF v_escrow.status NOT IN ('pending', 'held') THEN
    RETURN jsonb_build_object('success', true, 'skipped', true, 'status', v_escrow.status);
  END IF;

  v_cur    := COALESCE(v_escrow.currency, 'GNF');
  v_seller := COALESCE(v_escrow.receiver_id, v_escrow.seller_id);
  IF v_seller IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Vendeur manquant sur l''escrow');
  END IF;

  -- Commission VENDEUR = ce qui est STOCKÉ sur l'escrow (0 dans le modèle frais-acheteur).
  -- ❌ Plus de repli 2,5 % : le vendeur ne doit JAMAIS être amputé d'une commission non prévue.
  v_commission    := COALESCE(v_escrow.commission_amount, 0);
  v_vendor_amount := v_escrow.amount - v_commission;

  v_seller_res := public.credit_user_wallet_safe(v_seller, v_vendor_amount, v_cur, 'escrow_release', p_escrow_id::text);
  v_wallet_id  := (v_seller_res->>'wallet_id')::bigint;

  -- Garde fail-closed : si le crédit devait avoir lieu (pas un skip idempotent) mais
  -- n'a rien crédité NI quarantiné → ROLLBACK. Jamais un 'released' sans paiement réel.
  v_got := COALESCE((v_seller_res->>'credited')::numeric, 0) + COALESCE((v_seller_res->>'quarantined')::numeric, 0);
  IF v_vendor_amount > 0
     AND NOT COALESCE((v_seller_res->>'skipped')::boolean, false)
     AND v_got <= 0 THEN
    RAISE EXCEPTION 'ESCROW_RELEASE_CREDIT_ECHOUE (%)', COALESCE(v_seller_res->>'error', '?');
  END IF;

  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;
  IF v_pdg IS NOT NULL AND v_commission > 0 THEN
    PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, v_cur, 'escrow_commission', p_escrow_id::text);
  END IF;

  UPDATE public.escrow_transactions
  SET status = 'released', released_at = now(), commission_amount = v_commission, updated_at = now()
  WHERE id = p_escrow_id;

  INSERT INTO public.wallet_transactions (
    transaction_id, receiver_wallet_id, receiver_user_id, amount, fee, net_amount, currency,
    transaction_type, status, description, metadata)
  VALUES (
    generate_transaction_id(), v_wallet_id, v_seller, v_escrow.amount, v_commission, v_vendor_amount, v_cur,
    'escrow_release', 'completed', 'Fonds escrow libérés',
    jsonb_build_object('escrow_id', p_escrow_id, 'order_id', v_escrow.order_id, 'commission', v_commission,
      'credited', (v_seller_res->>'credited')::numeric, 'credited_currency', v_seller_res->>'currency',
      'quarantined', (v_seller_res->>'quarantined')::numeric, 'idempotent', COALESCE((v_seller_res->>'idempotent')::boolean, false),
      'reason', p_reason, 'original_currency', v_cur));

  RETURN jsonb_build_object('success', true, 'escrow_id', p_escrow_id, 'vendor_amount', v_vendor_amount,
    'credited', (v_seller_res->>'credited')::numeric, 'credited_currency', v_seller_res->>'currency',
    'quarantined', (v_seller_res->>'quarantined')::numeric, 'commission_amount', v_commission);
END;
$$;

REVOKE ALL ON FUNCTION public.release_escrow_to_seller(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.release_escrow_to_seller(uuid, text) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.release_escrow_to_seller(uuid, text) TO service_role;

SELECT 'FIX release_escrow_to_seller : garde fail-closed (crédit=0 sans skip → RAISE) — jamais un escrow ''released'' sans paiement vendeur.' AS status;
