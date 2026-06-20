-- ============================================================================
-- SYNCHRO LIVRAISON → COMMANDE RESTAURANT.
-- Quand le LIVREUR marque la course « delivered » (table deliveries), la commande
-- restaurant correspondante passe automatiquement à « completed ». Trigger DB = source
-- unique et infaillible (quel que soit le chemin qui met à jour la livraison : appli
-- livreur, backend, admin…). Idempotent, ne touche pas les commandes déjà closes/annulées.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.sync_restaurant_order_on_delivery()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.restaurant_order_id IS NOT NULL
     AND NEW.status = 'delivered'
     AND (OLD.status IS DISTINCT FROM 'delivered') THEN
    UPDATE public.restaurant_orders
    SET status       = 'completed',
        completed_at = COALESCE(completed_at, now()),
        updated_at   = now()
    WHERE id = NEW.restaurant_order_id
      AND status NOT IN ('completed', 'cancelled');
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_restaurant_order_on_delivery ON public.deliveries;
CREATE TRIGGER trg_sync_restaurant_order_on_delivery
  AFTER UPDATE OF status ON public.deliveries
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_restaurant_order_on_delivery();

SELECT 'Synchro posée : livraison « delivered » → commande restaurant « completed » (auto).' AS status;
