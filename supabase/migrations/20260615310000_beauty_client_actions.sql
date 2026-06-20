-- ============================================================================
-- BEAUTÉ — Phase 3 : actions CLIENT atomiques (annulation avec politique de pénalité,
-- avis vérifié). REVOKE FROM PUBLIC. Rejouable.
-- ============================================================================

-- ── RPC : annulation par le client (remboursement OU pénalité selon le délai) ──
CREATE OR REPLACE FUNCTION public.cancel_beauty_booking_atomic(p_actor_user_id uuid, p_appointment_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a public.beauty_appointments%ROWTYPE; v_provider uuid; v_window int; v_pct numeric;
        v_hours numeric; v_refund numeric; v_penalty numeric;
BEGIN
  SELECT * INTO a FROM public.beauty_appointments WHERE id = p_appointment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'NOT_FOUND'; END IF;
  IF a.customer_user_id <> p_actor_user_id THEN RAISE EXCEPTION 'NOT_CLIENT'; END IF;
  IF a.status NOT IN ('confirmed','pending','scheduled') THEN RAISE EXCEPTION 'NOT_CANCELLABLE'; END IF;

  SELECT user_id INTO v_provider FROM public.professional_services WHERE id = a.professional_service_id;
  SELECT COALESCE(cancel_window_hours,24), COALESCE(noshow_penalty_pct,50) INTO v_window, v_pct
  FROM public.beauty_settings WHERE professional_service_id = a.professional_service_id;
  v_window := COALESCE(v_window, 24); v_pct := COALESCE(v_pct, 50);

  v_hours := EXTRACT(EPOCH FROM ((a.appointment_date + a.appointment_time) - now())) / 3600.0;

  IF v_hours >= v_window THEN
    v_penalty := 0; v_refund := COALESCE(a.deposit_paid, 0);
  ELSE
    v_penalty := round(COALESCE(a.total_price,0) * v_pct / 100.0);
    v_refund := greatest(COALESCE(a.deposit_paid,0) - v_penalty, 0);
  END IF;

  IF v_refund > 0 AND v_provider IS NOT NULL THEN
    PERFORM public.wallet_debit_internal(v_provider, v_refund, 'Remboursement annulation beauté', 'beauty-cancel-' || a.id::text);
    PERFORM public.credit_user_wallet_safe(p_actor_user_id, v_refund, 'GNF', 'beauty_cancel_refund', a.id::text);
  END IF;

  UPDATE public.beauty_appointments
    SET status = 'cancelled', penalty_applied = COALESCE(a.deposit_paid,0) - v_refund
    WHERE id = p_appointment_id;

  RETURN jsonb_build_object('success', true, 'refunded', v_refund, 'penalty', COALESCE(a.deposit_paid,0) - v_refund);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.cancel_beauty_booking_atomic(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.cancel_beauty_booking_atomic(uuid, uuid) TO service_role;

-- ── RPC : avis vérifié (uniquement le client du RDV) ────────────────────────
CREATE OR REPLACE FUNCTION public.submit_beauty_review_atomic(p_actor_user_id uuid, p_appointment_id uuid, p_rating int, p_text text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a public.beauty_appointments%ROWTYPE;
BEGIN
  SELECT * INTO a FROM public.beauty_appointments WHERE id = p_appointment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'NOT_FOUND'; END IF;
  IF a.customer_user_id <> p_actor_user_id THEN RAISE EXCEPTION 'NOT_CLIENT'; END IF;
  IF p_rating < 1 OR p_rating > 5 THEN RAISE EXCEPTION 'BAD_RATING'; END IF;
  UPDATE public.beauty_appointments SET rating = p_rating, review_text = p_text WHERE id = p_appointment_id;
  RETURN jsonb_build_object('success', true);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.submit_beauty_review_atomic(uuid, uuid, int, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.submit_beauty_review_atomic(uuid, uuid, int, text) TO service_role;

SELECT 'Beauté Phase 3 : annulation (pénalité) + avis vérifié atomiques.' AS status;
