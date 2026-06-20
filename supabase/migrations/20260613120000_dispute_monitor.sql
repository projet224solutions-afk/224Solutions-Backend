-- 🩺 SURVEILLANCE DU SYSTÈME DE LITIGE (domaine 'dispute')
--
-- Domaine de monitoring dédié aux litiges escrow (escrow_disputes), branché sur le
-- framework générique <x>_monitor_report() → system_alerts. Détecte les incohérences
-- d'atomicité et les litiges qui traînent, pour que le PDG soit alerté automatiquement.
--
-- Checks :
--   disputes_open_overdue       : litige NON résolu depuis > 7 jours (client en attente).
--   disputes_refund_unfunded    : résolu 'refund_to_buyer' mais escrow ≠ 'refunded' (atomicité brisée).
--   disputes_release_unreleased : résolu 'release_to_seller' mais escrow ≠ 'released' (atomicité brisée).
--   disputes_double_open        : > 1 litige ouvert sur le même escrow (l'index unique devrait l'empêcher).
--   disputes_no_message_1d      : litige ouvert depuis > 1j sans aucun message (fil mort).

CREATE OR REPLACE FUNCTION public.dispute_monitor_report()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_overdue          int := 0;
  v_refund_unfunded  int := 0;
  v_release_unrel    int := 0;
  v_double_open      int := 0;
  v_no_message       int := 0;
BEGIN
  SELECT count(*) INTO v_overdue
  FROM public.escrow_disputes
  WHERE status <> 'resolved' AND created_at < now() - interval '7 days';

  SELECT count(*) INTO v_refund_unfunded
  FROM public.escrow_disputes d
  JOIN public.escrow_transactions e ON e.id = d.escrow_id
  WHERE d.status = 'resolved' AND d.resolution = 'refund_to_buyer'
    AND e.status <> 'refunded';

  SELECT count(*) INTO v_release_unrel
  FROM public.escrow_disputes d
  JOIN public.escrow_transactions e ON e.id = d.escrow_id
  WHERE d.status = 'resolved' AND d.resolution = 'release_to_seller'
    AND e.status <> 'released';

  SELECT COALESCE(sum(c - 1), 0) INTO v_double_open
  FROM (
    SELECT count(*) AS c
    FROM public.escrow_disputes
    WHERE status <> 'resolved'
    GROUP BY escrow_id
    HAVING count(*) > 1
  ) q;

  SELECT count(*) INTO v_no_message
  FROM public.escrow_disputes d
  WHERE d.status <> 'resolved'
    AND d.created_at < now() - interval '1 day'
    AND NOT EXISTS (
      SELECT 1 FROM public.dispute_messages m WHERE m.escrow_dispute_id = d.id
    );

  RETURN jsonb_build_object(
    'generated_at', now(),
    'checks', jsonb_build_array(
      jsonb_build_object('key','disputes_open_overdue','label','Litige non résolu > 7j (client en attente)','severity','high','count',v_overdue,'observed',v_overdue),
      jsonb_build_object('key','disputes_refund_unfunded','label','Litige remboursé mais escrow non remboursé (atomicité brisée)','severity','critical','count',v_refund_unfunded,'observed',v_refund_unfunded),
      jsonb_build_object('key','disputes_release_unreleased','label','Litige libéré mais escrow non libéré (atomicité brisée)','severity','critical','count',v_release_unrel,'observed',v_release_unrel),
      jsonb_build_object('key','disputes_double_open','label','Plusieurs litiges ouverts sur le même escrow','severity','high','count',v_double_open,'observed',v_double_open),
      jsonb_build_object('key','disputes_no_message_1d','label','Litige ouvert > 1j sans aucun message','severity','low','count',v_no_message,'observed',v_no_message)
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.dispute_monitor_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.dispute_monitor_report() TO service_role;
