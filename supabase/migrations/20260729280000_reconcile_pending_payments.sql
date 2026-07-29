-- ============================================================================
-- JOB DE RÉCONCILIATION (blindé C/B) — rien ne reste dans les limbes > 1 h
-- ----------------------------------------------------------------------------
-- `reconcile_pending_fx()` : relance le règlement des transactions bloquées en `pending_fx`
-- (le payeur a payé, les fonds sont chez le prestataire ; on attendait des taux FX sains).
-- Au retour des taux, le règlement passe et crédite ; sinon la ligne reste `pending_fx` (attente
-- propre, jamais un taux inventé). Chaque règlement est atomique (bloc EXCEPTION = savepoint :
-- si settle échoue, CETTE ligne reste pending_fx, les autres continuent). service_role only.
-- Planifié toutes les 10 min. Alerte si une ligne stagne > 1 h (déjà couverte par no_stale_pending_fx).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.reconcile_pending_fx()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  r RECORD; v_qr text; v_res jsonb;
  v_settled int := 0; v_still int := 0; v_skipped int := 0;
BEGIN
  FOR r IN
    SELECT id, provider, provider_ref, amount, currency, metadata
      FROM public.payment_transactions
     WHERE status = 'pending_fx'
     ORDER BY created_at ASC
     LIMIT 200
     FOR UPDATE SKIP LOCKED
  LOOP
    v_qr := r.metadata->>'qr_reference';
    IF v_qr IS NULL OR btrim(v_qr) = '' THEN v_skipped := v_skipped + 1; CONTINUE; END IF;
    BEGIN
      v_res := public.settle_qr_payment(v_qr, r.amount, r.currency, r.provider, r.provider_ref);
      IF COALESCE((v_res->>'success')::boolean, false) THEN
        UPDATE public.payment_transactions
           SET status = 'completed', credited_at = now(), updated_at = now()
         WHERE id = r.id;
        v_settled := v_settled + 1;
      ELSE
        v_still := v_still + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      -- FX toujours indisponible (ou autre) → on laisse pending_fx pour le prochain passage.
      v_still := v_still + 1;
    END;
  END LOOP;

  RETURN jsonb_build_object('settled', v_settled, 'still_pending_fx', v_still, 'skipped', v_skipped, 'checked_at', now());
END $function$;

REVOKE ALL ON FUNCTION public.reconcile_pending_fx() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.reconcile_pending_fx() TO service_role;

-- Planification toutes les 10 minutes (idempotent).
SELECT cron.schedule('reconcile-pending-fx', '*/10 * * * *', $$SELECT public.reconcile_pending_fx()$$);
