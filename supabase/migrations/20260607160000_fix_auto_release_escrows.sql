-- ⏰ RÉPARATION DU CRON D'AUTO-LIBÉRATION DES ESCROWS MARKETPLACE
--
-- BUG : auto_release_escrows() filtrait status='pending' + colonnes available_to_release_at /
-- auto_release_enabled, alors que create_order_core crée les escrows en status='held' avec
-- auto_release_at → AUCUN escrow marketplace n'était jamais auto-libéré (vendeurs jamais payés
-- si l'acheteur ne confirmait pas). Cette version traite les escrows 'held' échus, et seulement
-- pour des commandes effectivement expédiées/livrées (sécurité), en créditant le vendeur (net)
-- et la plateforme (commission = commission_amount stockée, sinon 5%).

CREATE OR REPLACE FUNCTION public.auto_release_escrows()
RETURNS TABLE(escrow_id uuid, success boolean, message text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_e            RECORD;
  v_commission   numeric;
  v_vendor_amount numeric;
  v_cur          text;
  v_seller       uuid;
  v_pdg_user_id  uuid;
BEGIN
  SELECT user_id INTO v_pdg_user_id FROM public.pdg_management WHERE is_active = true LIMIT 1;

  FOR v_e IN
    SELECT et.*
    FROM public.escrow_transactions et
    JOIN public.orders o ON o.id = et.order_id
    WHERE et.status = 'held'
      AND et.auto_release_at IS NOT NULL
      AND et.auto_release_at <= now()
      AND o.status IN ('delivered', 'in_transit')   -- sécurité : ne pas libérer une commande non expédiée
    ORDER BY et.auto_release_at ASC
    LIMIT 100
  LOOP
    BEGIN
      v_cur           := COALESCE(v_e.currency, 'GNF');
      v_seller        := COALESCE(v_e.receiver_id, v_e.seller_id);
      v_commission    := COALESCE(NULLIF(v_e.commission_amount, 0), v_e.amount * 0.05);
      v_vendor_amount := v_e.amount - v_commission;

      -- Crédit vendeur (net)
      UPDATE public.wallets SET balance = balance + v_vendor_amount, updated_at = now()
      WHERE user_id = v_seller AND currency = v_cur;
      IF NOT FOUND THEN
        INSERT INTO public.wallets (user_id, balance, currency, wallet_status)
        VALUES (v_seller, v_vendor_amount, v_cur, 'active');
      END IF;

      -- Crédit plateforme (commission)
      IF v_pdg_user_id IS NOT NULL AND v_commission > 0 THEN
        UPDATE public.wallets SET balance = balance + v_commission, updated_at = now()
        WHERE user_id = v_pdg_user_id AND currency = v_cur;
        IF NOT FOUND THEN
          INSERT INTO public.wallets (user_id, balance, currency, wallet_status)
          VALUES (v_pdg_user_id, v_commission, v_cur, 'active');
        END IF;
      END IF;

      INSERT INTO public.wallet_transactions (
        transaction_id, receiver_user_id, transaction_type, amount, net_amount, currency, status, description, metadata)
      VALUES (
        'rel-' || left(replace(gen_random_uuid()::text, '-', ''), 45),
        v_seller, 'escrow_release', v_e.amount, v_vendor_amount, v_cur, 'completed',
        'Fonds escrow libérés (auto J+7)',
        jsonb_build_object('escrow_id', v_e.id, 'order_id', v_e.order_id, 'commission', v_commission, 'auto', true));

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

REVOKE ALL ON FUNCTION public.auto_release_escrows() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.auto_release_escrows() TO service_role;

SELECT 'auto_release_escrows réparé (status=held + auto_release_at, crédit vendeur+plateforme).' AS status;
