-- Fonction pour créer automatiquement un abonnement free pour les nouveaux vendeurs
CREATE OR REPLACE FUNCTION public.create_free_subscription_for_vendor()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_free_plan_id UUID;
BEGIN
  -- Vérifier si le nouveau utilisateur est un vendeur
  IF NEW.role = 'vendeur' THEN
    -- Récupérer l'ID du plan free
    SELECT id INTO v_free_plan_id
    FROM public.plans
    WHERE name = 'free'
    LIMIT 1;

    -- Si le plan free existe, créer l'abonnement
    IF v_free_plan_id IS NOT NULL THEN
      -- Vérifier si l'utilisateur n'a pas déjà un abonnement
      IF NOT EXISTS (
        SELECT 1 FROM public.subscriptions
        WHERE user_id = NEW.id
      ) THEN
        -- Créer l'abonnement free
        INSERT INTO public.subscriptions (
          user_id,
          plan_id,
          price_paid_gnf,
          billing_cycle,
          status,
          started_at,
          current_period_end,
          auto_renew,
          payment_method
        ) VALUES (
          NEW.id,
          v_free_plan_id,
          0, -- Prix gratuit
          'lifetime', -- Cycle de facturation illimité
          'active', -- Statut actif
          NOW(),
          NOW() + INTERVAL '100 years', -- Date de fin très lointaine pour le plan gratuit
          false, -- Pas de renouvellement automatique pour le plan gratuit
          'free' -- Méthode de paiement
        );
        
        RAISE NOTICE 'Abonnement free créé pour le vendeur: %', NEW.id;
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- Créer le trigger qui s'exécute après l'insertion d'un profil
DROP TRIGGER IF EXISTS on_vendor_profile_created ON public.profiles;

CREATE TRIGGER on_vendor_profile_created
  AFTER INSERT ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.create_free_subscription_for_vendor();

-- Créer les abonnements free manquants pour les vendeurs existants
DO $$
DECLARE
  v_free_plan_id UUID;
  v_vendor_record RECORD;
BEGIN
  -- Récupérer l'ID du plan free
  SELECT id INTO v_free_plan_id
  FROM public.plans
  WHERE name = 'free'
  LIMIT 1;

  -- Si le plan free existe
  IF v_free_plan_id IS NOT NULL THEN
    -- Pour chaque vendeur sans abonnement
    FOR v_vendor_record IN (
      SELECT p.id
      FROM public.profiles p
      LEFT JOIN public.subscriptions s ON p.id = s.user_id
      WHERE p.role = 'vendeur'
        AND s.id IS NULL
    ) LOOP
      -- Créer l'abonnement free
      INSERT INTO public.subscriptions (
        user_id,
        plan_id,
        price_paid_gnf,
        billing_cycle,
        status,
        started_at,
        current_period_end,
        auto_renew,
        payment_method
      ) VALUES (
        v_vendor_record.id,
        v_free_plan_id,
        0,
        'lifetime',
        'active',
        NOW(),
        NOW() + INTERVAL '100 years',
        false,
        'free'
      );
      
      RAISE NOTICE 'Abonnement free rétroactif créé pour le vendeur: %', v_vendor_record.id;
    END LOOP;
  END IF;
END;
$$;