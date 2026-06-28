-- ============================================================================
-- PHARMACIE — AMÉLIORATION 2.1 : rappels de renouvellement d'ordonnance.
-- ⚠️ RÉUTILISE la colonne EXISTANTE `start_date` (PAS de `started_at` = doublon).
-- Ajoute seulement pharmacy_id (vers quelle pharmacie recommander) + anti-spam.
-- Confidentialité : le client ne voit QUE ses propres traitements (auth.uid()).
-- ============================================================================

BEGIN;

ALTER TABLE public.medication_reminders
  ADD COLUMN IF NOT EXISTS pharmacy_id UUID REFERENCES public.professional_services(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS last_renewal_notified_at TIMESTAMPTZ;

-- Le client voit SES traitements qui se terminent bientôt (auth.uid())
CREATE OR REPLACE FUNCTION public.my_treatments_ending_soon(p_days_ahead integer DEFAULT 3)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_uid uuid := auth.uid(); v_rows jsonb;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'NON_AUTHENTIFIE'); END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', id, 'medication_name', medication_name, 'started_at', start_date,
    'duration_days', duration_days,
    'ends_on', (start_date + (duration_days || ' days')::interval)::date,
    'days_left', ((start_date + (duration_days || ' days')::interval)::date - CURRENT_DATE),
    'pharmacy_id', pharmacy_id
  ) ORDER BY (start_date + (duration_days || ' days')::interval)), '[]'::jsonb)
  INTO v_rows
  FROM public.medication_reminders
  WHERE client_id = v_uid AND active = true
    AND start_date IS NOT NULL
    AND duration_days IS NOT NULL AND duration_days > 0
    AND (start_date + (duration_days || ' days')::interval)::date
        BETWEEN CURRENT_DATE AND CURRENT_DATE + (p_days_ahead || ' days')::interval;
  RETURN jsonb_build_object('success', true, 'treatments', v_rows);
END;
$$;

REVOKE ALL ON FUNCTION public.my_treatments_ending_soon(integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.my_treatments_ending_soon(integer) TO authenticated;

-- Worker : traitements à notifier (anti-spam 24h via last_renewal_notified_at)
CREATE OR REPLACE FUNCTION public.treatments_to_notify()
RETURNS TABLE(reminder_id uuid, client_id uuid, medication_name text, ends_on date)
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  SELECT id, client_id, medication_name,
         (start_date + (duration_days || ' days')::interval)::date
  FROM public.medication_reminders
  WHERE active = true
    AND start_date IS NOT NULL
    AND duration_days IS NOT NULL AND duration_days > 0
    AND (start_date + (duration_days || ' days')::interval)::date
        BETWEEN CURRENT_DATE AND CURRENT_DATE + interval '3 days'
    AND (last_renewal_notified_at IS NULL OR last_renewal_notified_at < now() - interval '24 hours');
$$;
GRANT EXECUTE ON FUNCTION public.treatments_to_notify() TO service_role;

DO $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_proc WHERE proname='my_treatments_ending_soon')
  THEN RAISE EXCEPTION 'RPC renouvellement absente'; END IF;
  RAISE NOTICE '✅ Migration medication_renewal OK';
END; $$;

COMMIT;
