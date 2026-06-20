-- ============================================================================
-- BEAUTÉ — créneaux occupés (déjà inclus dans 20260615130000 ; conservé idempotent).
-- Renvoie UNIQUEMENT les plages occupées (aucune donnée personnelle). Rejouable.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_beauty_busy_slots(p_service_id uuid, p_date date)
RETURNS TABLE (start_min integer, end_min integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT (extract(hour from appointment_time) * 60 + extract(minute from appointment_time))::int AS start_min,
         (extract(hour from appointment_time) * 60 + extract(minute from appointment_time) + COALESCE(duration_minutes, 30))::int AS end_min
  FROM public.beauty_appointments
  WHERE professional_service_id = p_service_id AND appointment_date = p_date AND status <> 'cancelled';
$$;
GRANT EXECUTE ON FUNCTION public.get_beauty_busy_slots(uuid, date) TO anon, authenticated;

SELECT 'RPC get_beauty_busy_slots (schéma professional_service_id/duration_minutes).' AS status;
