-- ============================================================================
-- 🔒🧱 LIVRAISON — cycle de vie ATOMIQUE (RPC SECURITY DEFINER, verrou FOR UPDATE).
--
-- Durcit accept/start/cancel/complete : chaque transition verrouille la ligne (FOR UPDATE),
-- vérifie l'AUTORISATION en base (défense en profondeur, même si le backend a un bug),
-- est IDEMPOTENTE (rejeu sûr) et TOUT-OU-RIEN. `complete` combine désormais la livraison ET
-- les totaux du livreur dans UNE SEULE transaction (avant : 2 updates séparés = état partiel
-- possible). Le crédit wallet reste fait par la primitive idempotente `creditWallet` côté backend
-- (clé `delivery-earning:<id>`) pour ne pas dupliquer la logique AML/plafond.
--
-- Toutes REVOKE FROM PUBLIC/anon, GRANT service_role uniquement (appelées par le backend).
-- ============================================================================

-- Détection « espèces » (pas de crédit wallet — encaissé en main propre).
CREATE OR REPLACE FUNCTION public._delivery_is_cash(p_method text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT lower(coalesce(p_method, '')) IN ('cash', 'cod', 'especes', 'espèces');
$$;

-- Gain livreur : driver_earning s'il est déjà fixé (>0), sinon 98,5 % des frais.
CREATE OR REPLACE FUNCTION public._delivery_earning(p_earning numeric, p_fee numeric)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_earning IS NOT NULL AND p_earning > 0 THEN p_earning
    ELSE round(coalesce(p_fee, 0) * 0.985)
  END;
$$;

-- ── ACCEPT : claim atomique (verrou + check pending/libre). Idempotent si déjà au livreur. ──
CREATE OR REPLACE FUNCTION public.accept_delivery(p_delivery_id uuid, p_driver_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_row public.deliveries%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM public.deliveries WHERE id = p_delivery_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'not_found');
  END IF;

  -- Déjà assignée à CE livreur et active → idempotent.
  IF v_row.driver_id = p_driver_id AND v_row.status IN ('assigned','picked_up','in_transit') THEN
    RETURN jsonb_build_object('success', true, 'already_assigned', true);
  END IF;

  -- Sinon, doit être libre (pending + sans livreur).
  IF v_row.status <> 'pending' OR v_row.driver_id IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'unavailable');
  END IF;

  UPDATE public.deliveries
     SET driver_id = p_driver_id, status = 'assigned', accepted_at = now()
   WHERE id = p_delivery_id;

  RETURN jsonb_build_object('success', true, 'status', 'assigned');
END;
$$;

-- ── START : assigned → picked_up (seul le livreur assigné). Idempotent si déjà en cours. ──
CREATE OR REPLACE FUNCTION public.start_delivery(p_delivery_id uuid, p_driver_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_row public.deliveries%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM public.deliveries WHERE id = p_delivery_id FOR UPDATE;
  IF NOT FOUND OR v_row.driver_id <> p_driver_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'not_owner');
  END IF;
  IF v_row.status IN ('picked_up','in_transit') THEN
    RETURN jsonb_build_object('success', true, 'already_started', true);
  END IF;
  IF v_row.status <> 'assigned' THEN
    RETURN jsonb_build_object('success', false, 'error', 'invalid_state');
  END IF;

  UPDATE public.deliveries
     SET status = 'picked_up', started_at = now()
   WHERE id = p_delivery_id;

  RETURN jsonb_build_object('success', true, 'status', 'picked_up');
END;
$$;

-- ── CANCEL : annule (seul le livreur assigné, pas si déjà livrée). Idempotent. ──
CREATE OR REPLACE FUNCTION public.cancel_delivery(p_delivery_id uuid, p_driver_id uuid, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_row public.deliveries%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM public.deliveries WHERE id = p_delivery_id FOR UPDATE;
  IF NOT FOUND OR v_row.driver_id <> p_driver_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'not_owner');
  END IF;
  IF v_row.status = 'delivered' THEN
    RETURN jsonb_build_object('success', false, 'error', 'already_delivered');
  END IF;
  IF v_row.status = 'cancelled' THEN
    RETURN jsonb_build_object('success', true, 'already_cancelled', true);
  END IF;

  UPDATE public.deliveries
     SET status = 'cancelled', cancelled_at = now(), cancel_reason = p_reason
   WHERE id = p_delivery_id;

  RETURN jsonb_build_object('success', true, 'status', 'cancelled');
END;
$$;

-- ── COMPLETE : livraison + gain + totaux livreur dans UNE transaction (tout-ou-rien).
--    NE crédite PAS le wallet ici (fait par creditWallet idempotent côté backend) mais renvoie
--    le gain + si espèces, pour que le backend décide. Idempotent : ne recompte les totaux
--    qu'au PREMIER passage en 'delivered'. ──
CREATE OR REPLACE FUNCTION public.complete_delivery(
  p_delivery_id uuid, p_driver_id uuid, p_proof text DEFAULT NULL, p_signature text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_row     public.deliveries%ROWTYPE;
  v_earning numeric;
  v_is_cash boolean;
  v_already boolean;
BEGIN
  SELECT * INTO v_row FROM public.deliveries WHERE id = p_delivery_id FOR UPDATE;
  IF NOT FOUND OR v_row.driver_id <> p_driver_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'not_owner');
  END IF;

  v_earning := public._delivery_earning(v_row.driver_earning, v_row.delivery_fee);
  v_is_cash := public._delivery_is_cash(v_row.payment_method);
  v_already := (v_row.status = 'delivered');

  IF NOT v_already THEN
    -- Marque livrée + écrit le gain + preuve (atomique).
    UPDATE public.deliveries
       SET status = 'delivered', completed_at = now(), driver_earning = v_earning,
           proof_photo_url = COALESCE(p_proof, proof_photo_url),
           client_signature = COALESCE(p_signature, client_signature),
           -- espèces : marquée réglée tout de suite (encaissée en main propre).
           driver_payment_method = CASE WHEN v_is_cash THEN lower(coalesce(v_row.payment_method,'cash'))
                                        ELSE driver_payment_method END
     WHERE id = p_delivery_id;

    -- Incrémente les totaux du livreur dans LA MÊME transaction (avant : update séparé).
    UPDATE public.drivers
       SET earnings_total = coalesce(earnings_total, 0) + v_earning,
           total_deliveries = coalesce(total_deliveries, 0) + 1,
           status = 'online'
     WHERE user_id = p_driver_id;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'driver_earning', v_earning,
    'is_cash', v_is_cash,
    'payment_method', lower(coalesce(v_row.payment_method, 'prepaid')),
    'already_completed', v_already,
    'already_paid', (v_row.driver_payment_method IS NOT NULL)
  );
END;
$$;

-- Verrouillage des grants : backend (service_role) uniquement.
REVOKE ALL ON FUNCTION public.accept_delivery(uuid, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.start_delivery(uuid, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cancel_delivery(uuid, uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.complete_delivery(uuid, uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.accept_delivery(uuid, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.start_delivery(uuid, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.cancel_delivery(uuid, uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.complete_delivery(uuid, uuid, text, text) TO service_role;

SELECT 'Cycle de vie livraison atomique : RPC accept/start/cancel/complete (FOR UPDATE + autorisation DB + idempotence), complete combine livraison+totaux en 1 transaction.' AS status;
