-- ============================================================================
-- BEAUTÉ — exposition PUBLIQUE des notes & avis (la RLS de beauty_appointments
-- réserve la lecture au client/prestataire ; ces RPC SECURITY DEFINER renvoient des
-- agrégats + avis SANS PII pour la découverte et la page salon). GRANT anon. Rejouable.
-- ============================================================================

-- Note moyenne + nombre d'avis par salon (batch, pour la page Découverte).
CREATE OR REPLACE FUNCTION public.get_beauty_provider_stats(p_service_ids uuid[])
RETURNS TABLE(professional_service_id uuid, avg_rating numeric, review_count bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT professional_service_id, round(avg(rating)::numeric, 1), count(*)
  FROM public.beauty_appointments
  WHERE professional_service_id = ANY(p_service_ids) AND rating IS NOT NULL
  GROUP BY professional_service_id;
$$;
REVOKE EXECUTE ON FUNCTION public.get_beauty_provider_stats(uuid[]) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.get_beauty_provider_stats(uuid[]) TO anon, authenticated, service_role;

-- Liste des avis vérifiés d'un salon (prénom seulement, note, commentaire, date, service).
CREATE OR REPLACE FUNCTION public.get_beauty_provider_reviews(p_service_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'name', split_part(COALESCE(a.customer_name, 'Client'), ' ', 1),
           'rating', a.rating,
           'comment', a.review_text,
           'date', a.appointment_date,
           'service', s.name
         ) ORDER BY a.appointment_date DESC), '[]'::jsonb)
  FROM public.beauty_appointments a
  LEFT JOIN public.beauty_services s ON s.id = a.beauty_service_id
  WHERE a.professional_service_id = p_service_id AND a.rating IS NOT NULL;
$$;
REVOKE EXECUTE ON FUNCTION public.get_beauty_provider_reviews(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.get_beauty_provider_reviews(uuid) TO anon, authenticated, service_role;

-- Répartition des notes (combien de 5★/4★/3★…) — pour le header de la page salon.
CREATE OR REPLACE FUNCTION public.get_beauty_rating_breakdown(p_service_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(jsonb_object_agg(rating, c), '{}'::jsonb) FROM (
    SELECT rating, count(*) c FROM public.beauty_appointments
    WHERE professional_service_id = p_service_id AND rating IS NOT NULL
    GROUP BY rating
  ) t;
$$;
REVOKE EXECUTE ON FUNCTION public.get_beauty_rating_breakdown(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.get_beauty_rating_breakdown(uuid) TO anon, authenticated, service_role;

SELECT 'Beauté : notes agrégées + avis vérifiés exposés publiquement (sans PII).' AS status;
