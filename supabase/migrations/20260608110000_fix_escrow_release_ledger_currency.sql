-- 🩹 CORRECTIF — « Échec de la libération des fonds » (suite) : contrainte CHECK (net_amount = amount - fee)
--
-- CAUSE : les RPC de libération écrivaient la ligne wallet_transactions avec amount EN DEVISE ESCROW
-- (ex. 61200 GNF) mais net_amount = montant CRÉDITÉ CONVERTI (ex. 5,97 EUR) → net_amount ≠ amount - fee
-- → viole la contrainte valid_net_amount / wallet_transactions_check.
--
-- FIX : la ligne d'historique reste DANS LA DEVISE DE L'ESCROW (amount/fee/net_amount tous en GNF,
-- net = amount - fee), currency = devise escrow. Le SOLDE est crédité du montant CONVERTI par
-- credit_user_wallet_safe (inchangé) ; le montant converti est stocké dans metadata. L'affichage
-- reconvertit pour le vendeur. Aucune autre logique modifiée.

-- ───────────── confirm_delivery_and_release_escrow ─────────────
CREATE OR REPLACE FUNCTION public.confirm_delivery_and_release_escrow(
  p_escrow_id   uuid,
  p_customer_id uuid,
  p_notes       text DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_escrow            RECORD;
  v_commission_amount numeric;
  v_vendor_amount     numeric;
  v_cur               text;
  v_seller            uuid;
  v_pdg               uuid;
  v_seller_res        jsonb;
  v_vendor_wallet_id  bigint;
BEGIN
  SELECT * INTO v_escrow FROM public.escrow_transactions WHERE id = p_escrow_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Transaction escrow introuvable';
  END IF;

  IF COALESCE(v_escrow.payer_id, v_escrow.buyer_id) <> p_customer_id THEN
    RAISE EXCEPTION 'Non autorisé: vous n''êtes pas le client de cette transaction';
  END IF;

  IF v_escrow.status NOT IN ('pending', 'held') THEN
    RAISE EXCEPTION 'Cette transaction ne peut pas être libérée (statut: %)', v_escrow.status;
  END IF;

  v_cur               := COALESCE(v_escrow.currency, 'GNF');
  v_seller            := COALESCE(v_escrow.receiver_id, v_escrow.seller_id);
  v_commission_amount := COALESCE(NULLIF(v_escrow.commission_amount, 0), v_escrow.amount * 0.025);
  v_vendor_amount     := v_escrow.amount - v_commission_amount;

  -- Crédit vendeur (net) converti dans la devise de SON wallet (anti-doublon + conversion)
  v_seller_res       := public.credit_user_wallet_safe(v_seller, v_vendor_amount, v_cur);
  v_vendor_wallet_id := (v_seller_res->>'wallet_id')::bigint;

  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;
  IF v_pdg IS NOT NULL AND v_commission_amount > 0 THEN
    PERFORM public.credit_user_wallet_safe(v_pdg, v_commission_amount, v_cur);
  END IF;

  UPDATE public.escrow_transactions
  SET status = 'released', released_at = now(), updated_at = now(), notes = COALESCE(p_notes, notes)
  WHERE id = p_escrow_id;

  INSERT INTO public.escrow_logs (escrow_id, action, performed_by, note)
  VALUES (p_escrow_id, 'customer_release', p_customer_id, p_notes);

  -- Ligne d'historique EN DEVISE ESCROW : net_amount = amount - fee (contrainte respectée).
  -- Le montant réellement crédité (converti) est dans metadata.credited.
  INSERT INTO public.wallet_transactions (
    transaction_id, receiver_wallet_id, amount, fee, net_amount, currency,
    transaction_type, status, description, metadata)
  VALUES (
    generate_transaction_id(), v_vendor_wallet_id, v_escrow.amount, v_commission_amount,
    v_vendor_amount, v_cur,
    'escrow_release', 'completed', 'Fonds libérés de l''escrow - Confirmation client',
    jsonb_build_object('escrow_id', p_escrow_id, 'commission', v_commission_amount,
      'vendor_amount', v_vendor_amount, 'credited', (v_seller_res->>'credited')::numeric,
      'credited_currency', v_seller_res->>'currency', 'confirmed_by', 'customer',
      'order_id', v_escrow.order_id, 'original_currency', v_cur));

  RETURN json_build_object('success', true, 'escrow_id', p_escrow_id,
    'vendor_amount', v_vendor_amount, 'credited', (v_seller_res->>'credited')::numeric,
    'credited_currency', v_seller_res->>'currency',
    'commission_amount', v_commission_amount, 'released_at', now());
EXCEPTION WHEN OTHERS THEN
  RAISE;
END;
$$;

-- ───────────── auto_release_escrows ─────────────
CREATE OR REPLACE FUNCTION public.auto_release_escrows()
RETURNS TABLE(escrow_id uuid, success boolean, message text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_e             RECORD;
  v_commission    numeric;
  v_vendor_amount numeric;
  v_cur           text;
  v_seller        uuid;
  v_pdg_user_id   uuid;
  v_seller_res    jsonb;
BEGIN
  SELECT user_id INTO v_pdg_user_id FROM public.pdg_management WHERE is_active = true LIMIT 1;

  FOR v_e IN
    SELECT et.*
    FROM public.escrow_transactions et
    JOIN public.orders o ON o.id = et.order_id
    WHERE et.status = 'held'
      AND et.auto_release_at IS NOT NULL
      AND et.auto_release_at <= now()
      AND o.status IN ('delivered', 'in_transit')
    ORDER BY et.auto_release_at ASC
    LIMIT 100
  LOOP
    BEGIN
      v_cur           := COALESCE(v_e.currency, 'GNF');
      v_seller        := COALESCE(v_e.receiver_id, v_e.seller_id);
      v_commission    := COALESCE(NULLIF(v_e.commission_amount, 0), v_e.amount * 0.05);
      v_vendor_amount := v_e.amount - v_commission;

      v_seller_res := public.credit_user_wallet_safe(v_seller, v_vendor_amount, v_cur);
      IF v_pdg_user_id IS NOT NULL AND v_commission > 0 THEN
        PERFORM public.credit_user_wallet_safe(v_pdg_user_id, v_commission, v_cur);
      END IF;

      -- Ligne d'historique EN DEVISE ESCROW : net_amount = amount - fee (contrainte respectée).
      INSERT INTO public.wallet_transactions (
        transaction_id, receiver_user_id, transaction_type, amount, fee, net_amount, currency,
        status, description, metadata)
      VALUES (
        'rel-' || left(replace(gen_random_uuid()::text, '-', ''), 45),
        v_seller, 'escrow_release', v_e.amount, v_commission, v_vendor_amount, v_cur,
        'completed', 'Fonds escrow libérés (auto J+7)',
        jsonb_build_object('escrow_id', v_e.id, 'order_id', v_e.order_id, 'commission', v_commission,
                           'credited', (v_seller_res->>'credited')::numeric,
                           'credited_currency', v_seller_res->>'currency',
                           'auto', true, 'original_currency', v_cur));

      UPDATE public.escrow_transactions
      SET status = 'released', released_at = now(), commission_amount = v_commission, updated_at = now()
      WHERE id = v_e.id;

      escrow_id := v_e.id; success := true; message := 'auto-released'; RETURN NEXT;
    EXCEPTION WHEN OTHERS THEN
      escrow_id := v_e.id; success := false; message := SQLERRM; RETURN NEXT;
    END;
  END LOOP;
END;
$$;

SELECT 'Libération escrow : ligne d''historique en devise escrow (net = amount - fee), solde crédité converti.' AS status;
