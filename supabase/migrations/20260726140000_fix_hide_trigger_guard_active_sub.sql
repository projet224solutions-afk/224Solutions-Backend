-- ============================================================================
-- CORRECTIF 🔴 — le trigger de masquage ne doit PAS masquer la boutique d'un
-- vendeur qui détient PAR AILLEURS un abonnement payant actif.
-- ============================================================================
-- Contexte : le modèle de données autorise plusieurs lignes d'abonnement par
-- user (le renouvellement crée souvent une NOUVELLE ligne 'active' au lieu de
-- mettre à jour l'existante ; l'ancienne bascule en 'expired' quelques jours
-- plus tard). Vérifié en prod le 2026-07-26 : 12 users à lignes multiples (tous
-- avec ≥1 active), 1 déjà exactement dans le motif dangereux, 3 avec 2 lignes
-- actives payantes simultanées.
--
-- Sans garde, la bascule 'expired' de l'ANCIENNE ligne déclenche le masquage de
-- TOUTE la boutique d'un client pourtant à jour (le trigger de réactivation ne
-- rattrape pas : il s'est déjà déclenché AVANT). La fonction de rattrapage
-- hide_pre_notified_expired_products() (20260725130000) avait déjà cette garde ;
-- on l'aligne ici sur le trigger PERMANENT (mêmes colonnes, mêmes statuts, même
-- condition de période).
--
-- Seule modification : ajout du bloc de garde. Le reste de la fonction (gate
-- 'payant→expired', préservation des désactivations manuelles is_active=false,
-- marqueur hidden_by_subscription, notification) est IDENTIQUE à 20260725120000.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.tg_hide_products_on_subscription_expiry()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_vendor uuid;
  v_count  int;
BEGIN
  -- Ne se déclenche QUE quand un abonnement PAYANT passe réellement à 'expired'.
  IF NOT (NEW.status = 'expired'
          AND COALESCE(OLD.price_paid_gnf, 0) > 0
          AND OLD.status IS DISTINCT FROM 'expired') THEN
    RETURN NEW;
  END IF;

  -- 🛡️ GARDE (ajoutée) : si le vendeur a PAR AILLEURS un abonnement payant actif
  -- et non expiré (autre ligne), il est à jour → NE RIEN MASQUER. Même condition
  -- que hide_pre_notified_expired_products() (statuts, price_paid_gnf, période).
  IF EXISTS (
    SELECT 1 FROM public.subscriptions s2
    WHERE s2.user_id = NEW.user_id
      AND s2.id <> NEW.id
      AND s2.status IN ('active','trialing')
      AND s2.price_paid_gnf > 0
      AND s2.current_period_end > now()
  ) THEN
    RETURN NEW;
  END IF;

  SELECT id INTO v_vendor FROM public.vendors WHERE user_id = NEW.user_id;
  IF v_vendor IS NULL THEN
    RETURN NEW;
  END IF;

  -- Masque UNIQUEMENT les produits actuellement actifs (préserve les désactivations
  -- manuelles : is_active=false reste false, hidden_by_subscription reste false).
  UPDATE public.products
     SET is_active = false, hidden_by_subscription = true, updated_at = now()
   WHERE vendor_id = v_vendor AND is_active = true;
  GET DIAGNOSTICS v_count = ROW_COUNT;

  IF v_count > 0 THEN
    INSERT INTO public.notifications (user_id, title, message, type, read, metadata)
    VALUES (
      NEW.user_id,
      'Abonnement expiré — produits masqués',
      'Votre abonnement a expiré. ' || v_count || ' de vos produits ne sont plus '
        || 'visibles dans le marketplace ni au point de vente. Renouvelez votre '
        || 'abonnement pour les réafficher automatiquement.',
      'subscription_expiry', false,
      jsonb_build_object('hidden_products', v_count, 'reason', 'subscription_expired')
    );
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.tg_hide_products_on_subscription_expiry() FROM PUBLIC;

-- Le trigger trg_hide_products_on_expiry (20260725120000) pointe déjà sur cette
-- fonction ; CREATE OR REPLACE suffit, pas besoin de recréer le trigger.
