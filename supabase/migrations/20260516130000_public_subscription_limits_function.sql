-- ================================================================
-- Fonction publique : limites d'abonnement actifs par service
-- Exposée en SECURITY DEFINER pour contourner la RLS
-- (la RLS bloque les non-admins sur service_subscriptions)
-- ================================================================
-- À exécuter dans Supabase Dashboard → SQL Editor
-- ================================================================

CREATE OR REPLACE FUNCTION public.get_active_service_subscription_limits()
RETURNS TABLE (
  professional_service_id UUID,
  max_products            INTEGER
)
LANGUAGE sql
SECURITY DEFINER   -- s'exécute avec les droits du propriétaire, pas de l'appelant
STABLE             -- résultat stable dans une même transaction (permet le cache)
AS $$
  SELECT
    ss.professional_service_id,
    sp.max_products
  FROM public.service_subscriptions ss
  JOIN public.service_plans sp ON sp.id = ss.plan_id
  WHERE ss.status             = 'active'
    AND ss.current_period_end >= now();
$$;

-- Autoriser les appels depuis le front (anon = visiteur, authenticated = utilisateur connecté)
GRANT EXECUTE ON FUNCTION public.get_active_service_subscription_limits() TO anon, authenticated;
