-- ============================================================================
-- ABONNEMENT RESTAURANT — PLAFOND DE PROMOTIONS PAR PLAN (Phase 3). Additif.
-- ----------------------------------------------------------------------------
-- AUDIT : commission par plan ✅ (resolve_service_commission_rate, expire→défaut),
-- plafond PLATS ✅ (trigger enforce_service_product_cap sur restaurant_menu_items).
-- TROU : la limite de PROMOTIONS par plan n'était appliquée NULLE PART (insert direct).
-- Spec : Gratuit = 0 promo · Basic = 1 active · Pro/Premium = illimité.
-- On applique côté SERVEUR (trigger BEFORE INSERT/UPDATE), infalsifiable par le frontend.
-- ============================================================================

-- 1) Colonne de plafond (NULL = illimité), + valeurs des plans restaurant.
ALTER TABLE public.service_plans ADD COLUMN IF NOT EXISTS max_active_promotions integer;

UPDATE public.service_plans SET max_active_promotions = 0
WHERE service_type_id = (SELECT id FROM public.service_types WHERE code = 'restaurant')
  AND monthly_price_gnf = 0;                       -- Gratuit → 0 promo

UPDATE public.service_plans SET max_active_promotions = 1
WHERE service_type_id = (SELECT id FROM public.service_types WHERE code = 'restaurant')
  AND monthly_price_gnf = 10000;                   -- Basic → 1 promo active
-- Pro (25000) / Premium (50000) restent NULL = illimité.

-- 2) Trigger : refuse une promo ACTIVE au-delà du plafond du plan d'abonnement ACTIF.
CREATE OR REPLACE FUNCTION public.enforce_restaurant_promotion_cap()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_max   integer;
  v_count integer;
BEGIN
  -- On ne contrôle que les promos ACTIVES (une promo désactivée ne compte pas).
  IF COALESCE(NEW.is_active, true) IS NOT TRUE THEN RETURN NEW; END IF;

  -- Plafond du plan d'abonnement ACTIF du restaurant (NULL = illimité).
  SELECT sp.max_active_promotions INTO v_max
  FROM public.service_subscriptions ss
  JOIN public.service_plans sp ON sp.id = ss.plan_id
  WHERE ss.professional_service_id = NEW.professional_service_id
    AND ss.status = 'active'
    AND ss.current_period_end > now()
  ORDER BY ss.current_period_end DESC
  LIMIT 1;

  IF NOT FOUND THEN
    v_max := 0;            -- aucun abonnement actif = plan Gratuit = 0 promotion
  END IF;
  IF v_max IS NULL THEN
    RETURN NEW;            -- plan Pro/Premium = illimité
  END IF;

  SELECT count(*) INTO v_count
  FROM public.restaurant_promotions
  WHERE professional_service_id = NEW.professional_service_id
    AND is_active = true
    AND (TG_OP = 'INSERT' OR id <> NEW.id);

  IF v_count >= v_max THEN
    RAISE EXCEPTION 'PROMO_LIMIT_REACHED: votre plan autorise % promotion(s) active(s) simultanée(s). Passez à un plan supérieur.', v_max
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cap_restaurant_promotions ON public.restaurant_promotions;
CREATE TRIGGER trg_cap_restaurant_promotions
  BEFORE INSERT OR UPDATE ON public.restaurant_promotions
  FOR EACH ROW EXECUTE FUNCTION public.enforce_restaurant_promotion_cap();

REVOKE ALL ON FUNCTION public.enforce_restaurant_promotion_cap() FROM PUBLIC;

SELECT 'Abonnement restaurant : plafond de promotions par plan (Gratuit 0 / Basic 1 / Pro·Premium illimité).' AS status;
