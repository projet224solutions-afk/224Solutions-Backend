-- ============================================================================
-- E-COMMERCE (PHASE 3) — ACHAT GROUPÉ « Tuan » (signature Pinduoduo).
-- ----------------------------------------------------------------------------
-- Un acheteur lance un achat groupé sur un produit (prix groupé, min participants,
-- expire 24h). Les autres rejoignent : à chaque participation, le wallet est débité
-- (fonds RETENUS par la plateforme). Si le minimum est atteint → le vendeur est crédité
-- (succès). Si expiré sans minimum → TOUS les participants sont remboursés (aucun débit net).
-- Atomique (verrou FOR UPDATE, idempotence par clé). REVOKE FROM PUBLIC. Rejouable.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.group_buys (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id        uuid,
  vendor_user_id    uuid REFERENCES auth.users(id),
  product_name      text,
  group_price       numeric(12,2) NOT NULL,
  min_participants  integer NOT NULL DEFAULT 3,
  participant_count integer NOT NULL DEFAULT 0,
  status            text NOT NULL DEFAULT 'open' CHECK (status IN ('open','succeeded','failed','cancelled')),
  expires_at        timestamptz NOT NULL DEFAULT (now() + interval '24 hours'),
  created_at        timestamptz DEFAULT now(),
  updated_at        timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_group_buys_status ON public.group_buys (status, expires_at);

CREATE TABLE IF NOT EXISTS public.group_buy_participants (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_buy_id  uuid NOT NULL REFERENCES public.group_buys(id) ON DELETE CASCADE,
  user_id       uuid NOT NULL REFERENCES auth.users(id),
  quantity      integer NOT NULL DEFAULT 1,
  amount        numeric(12,2) NOT NULL DEFAULT 0,
  refunded      boolean NOT NULL DEFAULT false,
  joined_at     timestamptz DEFAULT now(),
  UNIQUE (group_buy_id, user_id)
);

ALTER TABLE public.group_buys ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.group_buy_participants ENABLE ROW LEVEL SECURITY;
-- Lecture publique (page de partage du groupe) ; participants : chacun voit les siens.
DROP POLICY IF EXISTS group_buys_public_read ON public.group_buys;
CREATE POLICY group_buys_public_read ON public.group_buys FOR SELECT USING (true);
DROP POLICY IF EXISTS gbp_select ON public.group_buy_participants;
CREATE POLICY gbp_select ON public.group_buy_participants FOR SELECT USING (true);

-- ── Helper interne : crédite le vendeur (net commission 5%) quand le groupe réussit ──
CREATE OR REPLACE FUNCTION public.gb_settle_to_vendor_internal(p_group uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE g public.group_buys%ROWTYPE; v_total numeric; v_commission numeric; v_pdg uuid;
BEGIN
  SELECT * INTO g FROM public.group_buys WHERE id = p_group;
  SELECT COALESCE(sum(amount),0) INTO v_total FROM public.group_buy_participants WHERE group_buy_id = p_group AND NOT refunded;
  v_commission := round(v_total * 0.05);
  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;
  IF g.vendor_user_id IS NOT NULL AND v_total > 0 THEN
    PERFORM public.credit_user_wallet_safe(g.vendor_user_id, v_total - v_commission, 'GNF', 'group_buy_payout', p_group::text);
    IF v_pdg IS NOT NULL AND v_commission > 0 THEN
      PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, 'GNF', 'group_buy_commission', p_group::text);
    END IF;
  END IF;
END;
$$;

-- ── RPC : créer une campagne d'achat groupé (le créateur NE paie PAS ; les acheteurs
-- rejoignent ensuite via join_group_buy_atomic). Le vendeur = propriétaire du produit
-- (sinon le créateur). ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.create_group_buy_atomic(
  p_actor_user_id uuid, p_product_id uuid, p_product_name text, p_group_price numeric, p_min int, p_quantity int
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_vendor uuid; v_group uuid;
BEGIN
  IF p_actor_user_id IS NULL THEN RAISE EXCEPTION 'NO_ACTOR'; END IF;
  IF COALESCE(p_group_price,0) <= 0 THEN RAISE EXCEPTION 'BAD_PRICE'; END IF;
  BEGIN SELECT v.user_id INTO v_vendor FROM public.products p JOIN public.vendors v ON v.id = p.vendor_id WHERE p.id = p_product_id; EXCEPTION WHEN OTHERS THEN v_vendor := NULL; END;
  v_vendor := COALESCE(v_vendor, p_actor_user_id);

  INSERT INTO public.group_buys (product_id, vendor_user_id, product_name, group_price, min_participants)
  VALUES (p_product_id, v_vendor, p_product_name, p_group_price, GREATEST(2, COALESCE(p_min,3)))
  RETURNING id INTO v_group;

  RETURN jsonb_build_object('success', true, 'group_buy_id', v_group);
END;
$$;

-- ── RPC : rejoindre un achat groupé (débit + si minimum atteint → succès) ────
CREATE OR REPLACE FUNCTION public.join_group_buy_atomic(p_group uuid, p_actor_user_id uuid, p_quantity int)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE g public.group_buys%ROWTYPE; v_amount numeric; v_count int;
BEGIN
  SELECT * INTO g FROM public.group_buys WHERE id = p_group FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_NOT_FOUND'; END IF;
  IF g.status <> 'open' THEN RAISE EXCEPTION 'GROUP_CLOSED (%)', g.status; END IF;
  IF g.expires_at < now() THEN RAISE EXCEPTION 'GROUP_EXPIRED'; END IF;
  IF EXISTS (SELECT 1 FROM public.group_buy_participants WHERE group_buy_id = p_group AND user_id = p_actor_user_id) THEN
    RAISE EXCEPTION 'ALREADY_JOINED';
  END IF;

  v_amount := g.group_price * GREATEST(1, COALESCE(p_quantity,1));
  PERFORM public.wallet_debit_internal(p_actor_user_id, v_amount, 'Achat groupé ' || COALESCE(g.product_name,''), 'gb-join-' || p_group::text || '-' || p_actor_user_id::text);
  INSERT INTO public.group_buy_participants (group_buy_id, user_id, quantity, amount) VALUES (p_group, p_actor_user_id, GREATEST(1, COALESCE(p_quantity,1)), v_amount);

  SELECT count(*) INTO v_count FROM public.group_buy_participants WHERE group_buy_id = p_group AND NOT refunded;
  UPDATE public.group_buys SET participant_count = v_count, updated_at = now() WHERE id = p_group;

  -- Minimum atteint → succès : on règle le vendeur (les fonds retenus sont libérés).
  IF v_count >= g.min_participants THEN
    PERFORM public.gb_settle_to_vendor_internal(p_group);
    UPDATE public.group_buys SET status = 'succeeded', updated_at = now() WHERE id = p_group;
    RETURN jsonb_build_object('success', true, 'status', 'succeeded', 'count', v_count);
  END IF;
  RETURN jsonb_build_object('success', true, 'status', 'open', 'count', v_count, 'needed', g.min_participants - v_count);
END;
$$;

-- ── RPC : finaliser les groupes EXPIRÉS sans minimum → REMBOURSER tout le monde ─
CREATE OR REPLACE FUNCTION public.finalize_expired_group_buys() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE g RECORD; p RECORD; v_done int := 0;
BEGIN
  FOR g IN SELECT * FROM public.group_buys WHERE status = 'open' AND expires_at < now() FOR UPDATE LOOP
    FOR p IN SELECT * FROM public.group_buy_participants WHERE group_buy_id = g.id AND NOT refunded LOOP
      PERFORM public.credit_user_wallet_safe(p.user_id, p.amount, 'GNF', 'group_buy_refund', g.id::text);
      UPDATE public.group_buy_participants SET refunded = true WHERE id = p.id;
    END LOOP;
    UPDATE public.group_buys SET status = 'failed', updated_at = now() WHERE id = g.id;
    v_done := v_done + 1;
  END LOOP;
  RETURN v_done;
END;
$$;

-- ── Durcissement ────────────────────────────────────────────────────────────
REVOKE EXECUTE ON FUNCTION public.gb_settle_to_vendor_internal(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.create_group_buy_atomic(uuid, uuid, text, numeric, int, int) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.join_group_buy_atomic(uuid, uuid, int) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.finalize_expired_group_buys() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.create_group_buy_atomic(uuid, uuid, text, numeric, int, int) TO service_role;
GRANT  EXECUTE ON FUNCTION public.join_group_buy_atomic(uuid, uuid, int) TO service_role;
GRANT  EXECUTE ON FUNCTION public.finalize_expired_group_buys() TO service_role;

SELECT 'Achat groupé (Pinduoduo) créé : group_buys + participants + RPC atomiques durcies.' AS status;
