-- ============================================================================
-- 🛑 CORRECTIF : le vendeur doit recevoir le montant INTÉGRAL de l'escrow.
-- ----------------------------------------------------------------------------
-- CONSTAT (audit du 04/07/2026, commandes ORD-MR5MOBDQ-P1CR et ORD-MR4WMU52-EIXC) :
-- la version LIVE de release_escrow_to_seller contient encore le repli
--   v_commission := COALESCE(NULLIF(commission_amount,0), amount * 0.025)
-- → chaque libération ampute le vendeur de 2,5 % (625 GNF sur 25 000) alors que
-- le modèle « frais acheteur » (validé PDG) fait payer la commission PAR L'ACHETEUR
-- EN SUS à la commande (create_order_core). Résultat : commission perçue DEUX fois
-- (1 250 à la commande + 625 à la libération) et vendeur lésé.
--
-- CAUSE : 20260617470000_reapply_order_escrow_commission_fix.sql (version AVEC repli)
-- a été appliquée APRÈS 20260618190000_buyer_fee_commission_model.sql (version SANS
-- repli) — l'ordre d'application manuel a écrasé le correctif.
--
-- CETTE MIGRATION réapplique la version SANS repli (identique à 20260618190000 §2) :
--   • vendeur = amount − commission_STOCKÉE (0 dans le modèle frais-acheteur) ;
--   • crédit vendeur avec clé d'idempotence ('escrow_release', escrow_id) ;
--   • REVOKE PUBLIC + GRANT service_role uniquement.
-- Les 2 libérations déjà passées ont été régularisées (traces TXN-REG-RELFEE-*).
-- ============================================================================

-- 0) ── Prérequis : credit_user_wallet_safe à 5 paramètres (idempotence) ─────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'credit_user_wallet_safe' AND p.pronargs >= 5
  ) THEN
    RAISE EXCEPTION 'Prérequis manquant : appliquer d''abord 20260618160000_harden_wallet_credit_atomic.sql (credit_user_wallet_safe à 5 paramètres)';
  END IF;
END $$;

-- 1) ── release_escrow_to_seller : vendeur reçoit le montant INTÉGRAL ────────
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

-- 2) ── Vérification finale ──────────────────────────────────────────────────
SELECT CASE
  WHEN pg_get_functiondef(p.oid) LIKE '%0.025%'
    THEN '❌ ÉCHEC : le repli 2,5 % est encore présent'
  ELSE '✅ release_escrow_to_seller SANS repli — le vendeur reçoit le montant intégral'
END AS status
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'release_escrow_to_seller';
