-- ============================================================================
-- Masquage RÉTROACTIF « prévenir puis masquer » (décision Thierno 25/07)
-- ============================================================================
-- Le trigger d'expiration (20260725120000) ne masque qu'à la TRANSITION actif→expiré.
-- Les vendeurs déjà expirés AVANT le trigger gardaient leurs produits visibles.
-- Décision : les PRÉVENIR (notification avec échéance) PUIS masquer à l'échéance.
--
-- Ce mécanisme est GÉNÉRAL et réutilisable : masque les produits de tout vendeur
-- expiré ayant reçu une notification `reason='pre_hide_notice'` dont la `deadline`
-- est atteinte, et qui a encore des produits visibles. Idempotent (une fois masqués,
-- plus rien à faire). Se compose avec le trigger (immédiat) sans le remplacer.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.hide_pre_notified_expired_products()
RETURNS integer  -- nombre de vendeurs effectivement masqués
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  r       record;
  v_count int;
  total   int := 0;
BEGIN
  FOR r IN
    SELECT DISTINCT s.user_id, v.id AS vendor_id
    FROM public.subscriptions s
    JOIN public.vendors v ON v.user_id = s.user_id
    JOIN public.notifications n
      ON n.user_id = s.user_id AND n.metadata->>'reason' = 'pre_hide_notice'
    WHERE s.status = 'expired'
      AND (n.metadata->>'deadline')::date <= now()::date
      -- ⚠️ NE JAMAIS masquer un vendeur qui a un abonnement PAYANT ACTIF par ailleurs
      -- (une vieille ligne 'expired' peut coexister avec un abonnement en cours — c'est un
      -- client à jour, pas un expiré). Sans ce garde-fou on masque des clients payants.
      AND NOT EXISTS (
        SELECT 1 FROM public.subscriptions s2
        WHERE s2.user_id = s.user_id
          AND s2.status IN ('active','trialing')
          AND s2.price_paid_gnf > 0
          AND s2.current_period_end > now()
      )
      AND EXISTS (SELECT 1 FROM public.products p WHERE p.vendor_id = v.id AND p.is_active = true)
  LOOP
    UPDATE public.products
       SET is_active = false, hidden_by_subscription = true, updated_at = now()
     WHERE vendor_id = r.vendor_id AND is_active = true;
    GET DIAGNOSTICS v_count = ROW_COUNT;

    IF v_count > 0 THEN
      INSERT INTO public.notifications (user_id, title, message, type, read, metadata)
      VALUES (
        r.user_id,
        'Produits masqués — abonnement expiré',
        'Le délai est écoulé : vos ' || v_count || ' produit(s) ont été masqués du marketplace. '
          || 'Renouvelez votre abonnement pour les réafficher automatiquement.',
        'subscription_expiry', false,
        jsonb_build_object('reason','post_hide','hidden_products', v_count)
      );
      total := total + 1;
    END IF;
  END LOOP;

  RETURN total;
END;
$$;

REVOKE ALL ON FUNCTION public.hide_pre_notified_expired_products() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.hide_pre_notified_expired_products() TO service_role;

-- Job quotidien (06:30 UTC). Agit le jour où la deadline est atteinte, puis idempotent.
-- Remplaçable/annulable via cron.unschedule('retro-hide-pre-notified-expired').
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'retro-hide-pre-notified-expired') THEN
    PERFORM cron.unschedule('retro-hide-pre-notified-expired');
  END IF;
END $$;

SELECT cron.schedule(
  'retro-hide-pre-notified-expired',
  '30 6 * * *',
  $$SELECT public.hide_pre_notified_expired_products();$$
);
