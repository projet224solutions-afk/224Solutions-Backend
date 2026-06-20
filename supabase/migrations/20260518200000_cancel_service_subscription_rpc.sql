-- ================================================================
-- RPC cancel_service_subscription (2026-05-18)
--
-- Problème :
--   ServiceSubscriptionService.cancelSubscription() faisait un UPDATE
--   direct sur service_subscriptions. Si la RLS bloque les UPDATE
--   de l'utilisateur courant, la requête retourne 0 rows sans erreur
--   → annulation silencieusement ignorée.
--
-- Fix :
--   Fonction SECURITY DEFINER qui vérifie que l'appelant est bien le
--   propriétaire du service avant d'annuler l'abonnement.
--   Retourne TRUE si l'annulation a réussi, FALSE sinon.
-- ================================================================

CREATE OR REPLACE FUNCTION public.cancel_service_subscription(
  p_subscription_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner_user_id UUID;
BEGIN
  -- Vérifier que l'abonnement appartient à un service dont l'appelant est propriétaire
  SELECT ps.user_id INTO v_owner_user_id
  FROM public.service_subscriptions ss
  JOIN public.professional_services ps ON ps.id = ss.professional_service_id
  WHERE ss.id = p_subscription_id;

  -- Abonnement introuvable ou propriétaire différent → refus
  IF v_owner_user_id IS NULL OR v_owner_user_id IS DISTINCT FROM auth.uid() THEN
    RETURN FALSE;
  END IF;

  -- Annuler l'abonnement
  UPDATE public.service_subscriptions
  SET    status       = 'cancelled',
         auto_renew   = false,
         cancelled_at = now(),
         updated_at   = now()
  WHERE  id     = p_subscription_id
    AND  status != 'cancelled';

  RETURN FOUND;
END;
$$;

GRANT EXECUTE ON FUNCTION public.cancel_service_subscription(UUID) TO authenticated;

SELECT 'cancel_service_subscription — RPC SECURITY DEFINER créée.' AS status;
