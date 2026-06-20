-- ============================================================================
-- 💳 MODÈLE COMMISSION « FRAIS ACHETEUR » (validé PDG).
-- ----------------------------------------------------------------------------
-- Règle voulue : achat 100 000 + commission d'achat 5 % (5 000) → acheteur débité 105 000,
-- VENDEUR reçoit 100 000 (intégral, AUCUNE commission prélevée sur lui), plateforme garde 5 000.
--
-- Changements :
--   1) purchase_fee_percent = 5 (frais acheteur, en %).
--   2) release_escrow_to_seller : RETIRE le repli 2,5 % → le vendeur reçoit
--      escrow.amount − commission_STOCKÉE (qui sera 0 dans ce modèle) = montant intégral.
--   3) money_integrity_report : retire le contrôle « escrow sans commission » (devenu NORMAL,
--      la commission est désormais côté acheteur, pas vendeur).
-- NB : la commission VENDEUR = 0 est posée côté backend (PLATFORM_FEE_RATES = 0) → escrow.commission_amount = 0.
-- ============================================================================

-- 1) ── Frais acheteur = 5 % ──────────────────────────────────────────────────
INSERT INTO public.system_settings (setting_key, setting_value)
VALUES ('purchase_fee_percent', '5')
ON CONFLICT (setting_key) DO UPDATE SET setting_value = '5';

-- 2) ── release_escrow_to_seller : vendeur reçoit le montant INTÉGRAL (commission stockée=0) ──
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
GRANT EXECUTE ON FUNCTION public.release_escrow_to_seller(uuid, text) TO service_role;

-- 3) ── Watchdog : « escrow sans commission » devient NORMAL (commission côté acheteur) ──
CREATE OR REPLACE FUNCTION public.money_integrity_report()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_dup int; v_fx int; v_zc int;
BEGIN
  SELECT count(*) INTO v_dup FROM (
    SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname ~* '(credit_user_wallet_safe|create_order_core|release_escrow_to_seller|execute_atomic_wallet_transfer|refund_order_escrow|purchase_.*_subscription|create_pos_sale_complete)'
    GROUP BY p.proname HAVING count(*) > 1
  ) d;

  SELECT CASE WHEN EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'credit_user_wallet_safe'
      AND pg_get_functiondef(p.oid) LIKE '%FX_RATE_MISSING%'
  ) THEN 0 ELSE 1 END INTO v_fx;

  -- Libérations créditées à 0 (vendeur jamais payé), NON acquittées.
  SELECT count(*) INTO v_zc
  FROM public.wallet_transactions wt
  WHERE wt.transaction_type = 'escrow_release'
    AND COALESCE((wt.metadata->>'credited')::numeric, 0) = 0
    AND NOT EXISTS (SELECT 1 FROM public.money_integrity_acknowledged a
                    WHERE a.check_key = 'escrow_released_zero_credit' AND a.ref_id = wt.id::text);

  RETURN jsonb_build_object(
    'generated_at', now(),
    'checks', jsonb_build_array(
      jsonb_build_object('key','money_duplicate_overload','label','Surcharges de fonctions argent en double (drift)','severity','critical','count',v_dup,'observed',v_dup),
      jsonb_build_object('key','credit_fx_not_converting','label','credit_user_wallet_safe sans conversion de devise','severity','critical','count',v_fx,'observed',v_fx),
      jsonb_build_object('key','escrow_released_zero_credit','label','Libérations escrow créditées à 0 (vendeur non payé / quarantaine)','severity','warning','count',v_zc,'observed',v_zc)
    )
  );
END;
$$;
REVOKE ALL ON FUNCTION public.money_integrity_report() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.money_integrity_report() TO authenticated, service_role;

SELECT 'Modèle frais-acheteur : purchase_fee_percent=5, vendeur reçoit l''intégral (repli 2,5% retiré), commission vendeur=0 (PLATFORM_FEE_RATES backend à mettre à 0).' AS status;
