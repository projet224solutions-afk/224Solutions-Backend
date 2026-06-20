-- ============================================================================
-- PHASE 1 (correctif) — PLAFOND PRODUITS BLINDÉ AU NIVEAU BASE (non contournable)
-- ----------------------------------------------------------------------------
-- max_products des plans n'était appliqué nulle part pour les modules Farm / Resto /
-- Beauté (insert direct via RLS). Un contrôle front serait contournable. Ce trigger
-- BEFORE INSERT refuse la création au-delà du max_products du plan d'abonnement ACTIF
-- (repli sur le plan « free » du type de service si aucun abonnement payant actif).
-- Générique : réutilisable sur tout futur table-produit ayant professional_service_id.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.enforce_service_product_cap()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_max   integer;
  v_count bigint;
BEGIN
  -- 1) Limite du plan d'abonnement ACTIF du service
  SELECT sp.max_products INTO v_max
  FROM public.service_subscriptions ss
  JOIN public.service_plans sp ON sp.id = ss.plan_id
  WHERE ss.professional_service_id = NEW.professional_service_id
    AND ss.status = 'active'
    AND ss.current_period_end > now()
  ORDER BY ss.current_period_end DESC
  LIMIT 1;

  -- 2) Aucun abonnement payant actif → plan « free » du type de service
  IF v_max IS NULL THEN
    SELECT sp.max_products INTO v_max
    FROM public.professional_services psv
    JOIN public.service_plans sp
      ON sp.service_type_id = psv.service_type_id AND sp.name = 'free'
    WHERE psv.id = NEW.professional_service_id
    LIMIT 1;
  END IF;

  -- 3) Aucun plan défini → pas de plafond
  IF v_max IS NULL THEN
    RETURN NEW;
  END IF;

  EXECUTE format('SELECT count(*) FROM public.%I WHERE professional_service_id = $1', TG_TABLE_NAME)
    INTO v_count
    USING NEW.professional_service_id;

  IF v_count >= v_max THEN
    RAISE EXCEPTION 'Limite de % éléments atteinte pour votre plan d''abonnement. Passez à un plan supérieur pour en publier davantage.', v_max
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_service_product_cap() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_cap_farm_products       ON public.farm_products;
DROP TRIGGER IF EXISTS trg_cap_restaurant_menu     ON public.restaurant_menu_items;
DROP TRIGGER IF EXISTS trg_cap_beauty_services     ON public.beauty_services;

CREATE TRIGGER trg_cap_farm_products    BEFORE INSERT ON public.farm_products
  FOR EACH ROW EXECUTE FUNCTION public.enforce_service_product_cap();
CREATE TRIGGER trg_cap_restaurant_menu  BEFORE INSERT ON public.restaurant_menu_items
  FOR EACH ROW EXECUTE FUNCTION public.enforce_service_product_cap();
CREATE TRIGGER trg_cap_beauty_services  BEFORE INSERT ON public.beauty_services
  FOR EACH ROW EXECUTE FUNCTION public.enforce_service_product_cap();

SELECT 'Trigger de plafond produits posé sur farm_products / restaurant_menu_items / beauty_services.' AS status;
