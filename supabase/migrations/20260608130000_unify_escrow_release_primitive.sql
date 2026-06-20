-- 🧱🧱 DURCISSEMENT BÉTON DE LA LIBÉRATION ESCROW — primitive unique, atomique, idempotente
--
-- Avant : 3 implémentations de la libération vendeur (confirm_delivery_and_release_escrow,
-- auto_release_escrows, job escrow.auto-release) dupliquaient le calcul commission + crédit + ledger,
-- avec des risques : pas de verrou (double-libération possible), atomicité partielle (job = plusieurs
-- appels séparés), divergence de logique. Chaque bug devait être corrigé à 3 endroits.
--
-- Après : UNE primitive canonique release_escrow_to_seller(escrow_id, reason) :
--   • verrou FOR UPDATE sur l'escrow → impossible de libérer deux fois en concurrence,
--   • idempotente : si déjà libéré → renvoie {skipped:true} sans rien faire,
--   • crédit vendeur + commission PDG via credit_user_wallet_safe (CONVERSION garantie),
--   • ligne d'historique en devise escrow (net = amount - fee → contrainte respectée),
--   • le tout dans UNE transaction.
-- confirm_delivery_and_release_escrow et auto_release_escrows ne font plus que l'autorisation /
-- l'éligibilité puis appellent la primitive. Le job backend l'appelle aussi (cf. jobQueue.ts).

-- ───────────────────────── PRIMITIVE CANONIQUE ─────────────────────────
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
  -- Verrou : sérialise les libérations concurrentes du même escrow
  SELECT * INTO v_escrow FROM public.escrow_transactions WHERE id = p_escrow_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Escrow introuvable');
  END IF;

  -- Idempotent : déjà libéré/remboursé → ne rien faire
  IF v_escrow.status NOT IN ('pending', 'held') THEN
    RETURN jsonb_build_object('success', true, 'skipped', true, 'status', v_escrow.status);
  END IF;

  v_cur           := COALESCE(v_escrow.currency, 'GNF');
  v_seller        := COALESCE(v_escrow.receiver_id, v_escrow.seller_id);
  IF v_seller IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Vendeur manquant sur l''escrow');
  END IF;
  v_commission    := COALESCE(NULLIF(v_escrow.commission_amount, 0), v_escrow.amount * 0.025);
  v_vendor_amount := v_escrow.amount - v_commission;

  -- Crédit vendeur (net) + commission PDG, CONVERTIS dans la devise de chaque wallet
  v_seller_res := public.credit_user_wallet_safe(v_seller, v_vendor_amount, v_cur);
  v_wallet_id  := (v_seller_res->>'wallet_id')::bigint;

  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;
  IF v_pdg IS NOT NULL AND v_commission > 0 THEN
    PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, v_cur);
  END IF;

  -- Statut escrow
  UPDATE public.escrow_transactions
  SET status = 'released', released_at = now(), commission_amount = v_commission, updated_at = now()
  WHERE id = p_escrow_id;

  -- Ligne d'historique EN DEVISE ESCROW (net = amount - fee). Montant converti dans metadata.
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

REVOKE ALL ON FUNCTION public.release_escrow_to_seller(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.release_escrow_to_seller(uuid, text) TO service_role;

-- ───────────── confirm_delivery_and_release_escrow → auth + primitive ─────────────
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
  v_payer  uuid;
  v_buyer  uuid;
  v_status text;
  v_res    jsonb;
BEGIN
  SELECT payer_id, buyer_id, status INTO v_payer, v_buyer, v_status
  FROM public.escrow_transactions WHERE id = p_escrow_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Transaction escrow introuvable';
  END IF;
  IF COALESCE(v_payer, v_buyer) <> p_customer_id THEN
    RAISE EXCEPTION 'Non autorisé: vous n''êtes pas le client de cette transaction';
  END IF;

  v_res := public.release_escrow_to_seller(p_escrow_id, 'customer_confirmation');

  -- Déjà libéré (idempotent) → succès
  IF COALESCE((v_res->>'skipped')::boolean, false) THEN
    RETURN json_build_object('success', true, 'already_released', true, 'escrow_id', p_escrow_id);
  END IF;
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION '%', COALESCE(v_res->>'error', 'Échec de la libération');
  END IF;

  -- Notes + journal (best-effort)
  UPDATE public.escrow_transactions SET notes = COALESCE(p_notes, notes) WHERE id = p_escrow_id;
  BEGIN
    INSERT INTO public.escrow_logs (escrow_id, action, performed_by, note)
    VALUES (p_escrow_id, 'customer_release', p_customer_id, p_notes);
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  RETURN json_build_object('success', true, 'escrow_id', p_escrow_id,
    'vendor_amount', (v_res->>'vendor_amount')::numeric,
    'credited', (v_res->>'credited')::numeric, 'credited_currency', v_res->>'credited_currency',
    'commission_amount', (v_res->>'commission_amount')::numeric, 'released_at', now());
END;
$$;

-- ───────────── auto_release_escrows → éligibilité + primitive ─────────────
CREATE OR REPLACE FUNCTION public.auto_release_escrows()
RETURNS TABLE(escrow_id uuid, success boolean, message text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id  uuid;
  v_res jsonb;
BEGIN
  FOR v_id IN
    SELECT et.id
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
      v_res     := public.release_escrow_to_seller(v_id, 'auto_release_j7');
      escrow_id := v_id;
      success   := COALESCE((v_res->>'success')::boolean, false);
      message   := COALESCE(v_res->>'error',
                     CASE WHEN COALESCE((v_res->>'skipped')::boolean, false) THEN 'skipped' ELSE 'released' END);
      RETURN NEXT;
    EXCEPTION WHEN OTHERS THEN
      escrow_id := v_id; success := false; message := SQLERRM; RETURN NEXT;
    END;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.auto_release_escrows() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.auto_release_escrows() TO service_role;

SELECT 'Libération escrow unifiée : primitive release_escrow_to_seller (FOR UPDATE + idempotente + conversion + atomique).' AS status;
