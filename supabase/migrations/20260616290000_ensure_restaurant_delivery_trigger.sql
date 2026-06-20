-- ============================================================================
-- FILET DE SÉCURITÉ — création INFAILLIBLE de la course de livraison.
--
-- Avant : la course `deliveries` n'était créée QUE par le backend (/accept →
-- ensureRestaurantDelivery). Si le restaurateur acceptait via le REPLI Supabase
-- (backend injoignable) ou par tout autre chemin (Panel, admin…), la commande
-- passait « preparing » SANS course → aucun livreur dispatché, et les frais de
-- livraison déjà payés restaient séquestrés sans bénéficiaire.
--
-- Fix ATOMIQUE & UNIVERSEL : un trigger DB crée la course dès qu'une commande EN
-- LIVRAISON entre dans un statut accepté (confirmed/preparing/ready), quel que soit
-- le chemin. Idempotent (1 course/commande, garanti par l'index unique partiel +
-- garde EXISTS + capture unique_violation). Non bloquant pour l'acceptation.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.ensure_restaurant_delivery()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_svc   record;
  v_name  text;
  v_phone text;
BEGIN
  -- Uniquement les livraisons entrées dans un statut « accepté ».
  IF NEW.order_type <> 'delivery' THEN RETURN NEW; END IF;
  IF NEW.status NOT IN ('confirmed', 'preparing', 'ready') THEN RETURN NEW; END IF;

  -- Idempotence (cas normal) : une course existe déjà pour cette commande → rien à faire.
  IF EXISTS (SELECT 1 FROM public.deliveries WHERE restaurant_order_id = NEW.id) THEN
    RETURN NEW;
  END IF;

  SELECT business_name, phone, address, latitude, longitude
    INTO v_svc
  FROM public.professional_services WHERE id = NEW.professional_service_id;

  -- Contact client : depuis la commande, sinon depuis le profil (le livreur DOIT pouvoir joindre).
  v_name := NEW.customer_name;
  v_phone := NEW.customer_phone;
  IF (v_name IS NULL OR v_phone IS NULL) AND NEW.customer_user_id IS NOT NULL THEN
    SELECT
      COALESCE(v_name, p.full_name, NULLIF(trim(COALESCE(p.first_name,'') || ' ' || COALESCE(p.last_name,'')), '')),
      COALESCE(v_phone, p.phone)
      INTO v_name, v_phone
    FROM public.profiles p WHERE p.id = NEW.customer_user_id;
  END IF;

  -- Création de la course (best-effort, ne bloque jamais l'acceptation de la commande).
  BEGIN
    INSERT INTO public.deliveries (
      restaurant_order_id, status, delivery_fee, client_id, package_type,
      vendor_name, customer_name, customer_phone, pickup_address, delivery_address)
    VALUES (
      NEW.id, 'pending', 0, NEW.customer_user_id, 'restaurant',
      COALESCE(v_svc.business_name, 'Restaurant'), COALESCE(v_name, 'Client'), v_phone,
      jsonb_build_object('name', COALESCE(v_svc.business_name, 'Restaurant'), 'phone', v_svc.phone,
                         'address', v_svc.address, 'lat', v_svc.latitude, 'lng', v_svc.longitude),
      jsonb_build_object('text', NEW.delivery_address, 'name', v_name, 'phone', v_phone));
  EXCEPTION
    WHEN unique_violation THEN
      NULL;  -- course créée en concurrence (backend /accept) → OK
    WHEN OTHERS THEN
      RAISE WARNING 'ensure_restaurant_delivery %: %', NEW.id, SQLERRM;  -- ne casse pas l'acceptation
  END;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_ensure_restaurant_delivery ON public.restaurant_orders;
CREATE TRIGGER trg_ensure_restaurant_delivery
  AFTER INSERT OR UPDATE OF status ON public.restaurant_orders
  FOR EACH ROW EXECUTE FUNCTION public.ensure_restaurant_delivery();

SELECT 'Filet de sécurité : la course de livraison est créée par trigger DB à l acceptation, quel que soit le chemin (backend, repli, admin).' AS status;
