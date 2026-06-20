-- 🩹 (1) Commission vendeur (libération escrow) tracée + (2) nouveau contrôle de surveillance "fuite escrow"
--
-- 1. release_escrow_to_seller créditait la commission PDG via credit_user_wallet_safe SANS ligne
--    d'historique → invisible dans l'historique PDG. On ajoute une ligne wallet_transactions
--    (type=commission, "Commission vendeur (libération escrow)") en devise escrow (net=amount),
--    montant converti dans metadata.credited.
-- 2. escrow_monitor_report : nouveau contrôle escrow_amount_mismatch = escrow dont amount > subtotal
--    de la commande (la commission acheteur s'est glissée dans l'escrow → vendeur sur-payé = fuite).
--    Le bug est corrigé côté backend (escrow.amount = subtotal), ce contrôle détecte toute régression.

-- ───────────── release_escrow_to_seller (+ ligne commission PDG) ─────────────
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
  v_pdg_res       jsonb;
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
  v_commission    := COALESCE(NULLIF(v_escrow.commission_amount, 0), v_escrow.amount * 0.025);
  v_vendor_amount := v_escrow.amount - v_commission;

  -- Crédit vendeur (net) converti
  v_seller_res := public.credit_user_wallet_safe(v_seller, v_vendor_amount, v_cur);
  v_wallet_id  := (v_seller_res->>'wallet_id')::bigint;

  -- Crédit commission PDG converti + LIGNE D'HISTORIQUE (visibilité)
  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;
  IF v_pdg IS NOT NULL AND v_commission > 0 THEN
    v_pdg_res := public.credit_user_wallet_safe(v_pdg, v_commission, v_cur);
    INSERT INTO public.wallet_transactions (
      transaction_id, sender_user_id, receiver_user_id, amount, net_amount, currency,
      transaction_type, status, description, metadata)
    VALUES (
      generate_transaction_id(), NULL, v_pdg, v_commission, v_commission, v_cur,
      'commission', 'completed', 'Commission vendeur (libération escrow)',
      jsonb_build_object('escrow_id', p_escrow_id, 'order_id', v_escrow.order_id,
        'credited', (v_pdg_res->>'credited')::numeric, 'credited_currency', v_pdg_res->>'currency',
        'source', 'escrow_release_commission', 'original_currency', v_cur));
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
      'reason', p_reason, 'original_currency', v_cur));

  RETURN jsonb_build_object('success', true, 'escrow_id', p_escrow_id, 'vendor_amount', v_vendor_amount,
    'credited', (v_seller_res->>'credited')::numeric, 'credited_currency', v_seller_res->>'currency',
    'commission_amount', v_commission);
END;
$$;

-- ───────────── escrow_monitor_report (+ contrôle escrow_amount_mismatch) ─────────────
CREATE OR REPLACE FUNCTION public.escrow_monitor_report()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_non_converted   int;
  v_net_mismatch    int;
  v_cur_mismatch    int;
  v_no_ledger       int;
  v_held_overdue    int;
  v_stale_rates     int;
  v_rapid           int;
  v_escrow_mismatch int;
BEGIN
  SELECT count(*) INTO v_non_converted FROM public.wallet_transactions
  WHERE transaction_type = 'payment' AND description LIKE 'Libération escrow%'
    AND created_at > now() - interval '7 days';

  SELECT count(*) INTO v_net_mismatch FROM public.wallet_transactions
  WHERE COALESCE(net_amount, 0) <> COALESCE(amount, 0) - COALESCE(fee, 0)
    AND created_at > now() - interval '7 days';

  SELECT count(*) INTO v_cur_mismatch FROM public.wallet_transactions wt
  JOIN public.escrow_transactions e ON e.id::text = wt.metadata->>'escrow_id'
  WHERE wt.transaction_type = 'escrow_release'
    AND wt.currency <> COALESCE(e.currency, 'GNF')
    AND wt.created_at > now() - interval '7 days';

  SELECT count(*) INTO v_no_ledger FROM public.escrow_transactions e
  WHERE e.status = 'released' AND e.released_at > now() - interval '7 days'
    AND NOT EXISTS (
      SELECT 1 FROM public.wallet_transactions wt
      WHERE wt.transaction_type = 'escrow_release'
        AND (wt.reference_id = e.id::text OR wt.metadata->>'escrow_id' = e.id::text));

  SELECT count(*) INTO v_held_overdue FROM public.escrow_transactions
  WHERE status = 'held' AND auto_release_at IS NOT NULL
    AND auto_release_at < now() - interval '14 days';

  SELECT count(*) INTO v_stale_rates FROM public.currency_exchange_rates
  WHERE is_active = true AND (from_currency = 'GNF' OR to_currency = 'GNF')
    AND COALESCE(retrieved_at, timestamptz '2000-01-01') < now() - interval '24 hours';

  SELECT count(*) INTO v_rapid FROM public.wallet_transactions
  WHERE transaction_type IN ('escrow_release', 'refund')
    AND created_at > now() - interval '5 minutes';

  -- NOUVEAU : escrow dont le montant dépasse le subtotal produit de la commande (commission acheteur
  -- glissée dans l'escrow → vendeur sur-payé = fuite). 0 = sain.
  SELECT count(*) INTO v_escrow_mismatch FROM public.escrow_transactions e
  JOIN public.orders o ON o.id = e.order_id
  WHERE o.subtotal IS NOT NULL AND e.amount > o.subtotal + 0.01
    AND e.created_at > now() - interval '30 days';

  RETURN jsonb_build_object(
    'generated_at', now(),
    'checks', jsonb_build_array(
      jsonb_build_object('key','non_converted_releases','label','Libérations non converties (Edge cassée)','severity','critical','count',v_non_converted,'observed',v_non_converted),
      jsonb_build_object('key','net_mismatch','label','Incohérence net ≠ montant − frais','severity','critical','count',v_net_mismatch,'observed',v_net_mismatch),
      jsonb_build_object('key','currency_mismatch','label','Devise de libération ≠ devise escrow','severity','high','count',v_cur_mismatch,'observed',v_cur_mismatch),
      jsonb_build_object('key','released_no_ledger','label','Escrow libéré sans trace d''historique','severity','high','count',v_no_ledger,'observed',v_no_ledger),
      jsonb_build_object('key','held_overdue','label','Escrow bloqué > 14j (cron en panne ?)','severity','medium','count',v_held_overdue,'observed',v_held_overdue),
      jsonb_build_object('key','stale_rates','label','Taux BCRG périmés > 24h (conversion à risque)','severity','high','count',v_stale_rates,'observed',v_stale_rates),
      jsonb_build_object('key','rapid_ops','label','Opérations escrow rapides (5 min) — possible attaque','severity',CASE WHEN v_rapid > 30 THEN 'high' ELSE 'low' END,'count',CASE WHEN v_rapid > 30 THEN v_rapid ELSE 0 END,'observed',v_rapid),
      jsonb_build_object('key','escrow_amount_mismatch','label','Escrow > montant produit (commission acheteur incluse → fuite)','severity','critical','count',v_escrow_mismatch,'observed',v_escrow_mismatch)
    )
  );
END;
$$;

SELECT 'release_escrow_to_seller loggue la commission PDG + escrow_monitor_report détecte la fuite escrow.' AS status;
