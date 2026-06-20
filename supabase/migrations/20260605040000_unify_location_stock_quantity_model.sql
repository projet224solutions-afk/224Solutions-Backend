-- =====================================================================
-- UNIFICATION du double modèle de quantité de location_stock
-- =====================================================================
-- BUG : le trigger sync_location_stock_units (migration 20260409123000)
-- recalculait toujours `quantity := total_units` (total_units dérivé des
-- cartons). Conséquence : toute écriture DIRECTE sur `quantity` — ce que font
-- TOUTES les RPC entrepôt (ship_transfer, confirm_transfer_reception,
-- adjust_location_stock_atomic) — était ÉCRASÉE par l'ancienne valeur de
-- total_units dès que les cartons/total_units étaient peuplés → décréments /
-- incréments de stock PERDUS → stock entrepôt faux.
--
-- CORRECTIF (« do-what-I-mean ») : la DIMENSION MODIFIÉE devient l'autoritaire ;
-- les autres en dérivent. `quantity` et `total_units` restent toujours égaux.
--   - cartons/unités modifiés → total_units = cartons×upc + unités
--   - total_units modifié     → cartons/unités dérivés de total_units
--   - quantity modifié (RPC)  → total_units = quantity, cartons/unités dérivés
-- Sur INSERT : priorité cartons/unités, puis total_units, puis quantity.
-- `quantity` reste le miroir de total_units (compat héritée) ;
-- available_quantity = total_units − reserved_quantity.
--
-- Aucune réécriture de données : l'ancien trigger forçait déjà quantity=total_units
-- sur chaque écriture, donc les lignes existantes sont déjà cohérentes ; ce fix
-- empêche les pertes FUTURES. Idempotent.
--
-- À exécuter dans Supabase Dashboard → SQL Editor → Run (APRÈS 20260409123000).
-- =====================================================================

CREATE OR REPLACE FUNCTION public.sync_location_stock_units()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.units_per_carton        := GREATEST(COALESCE(NEW.units_per_carton, 1), 1);
  NEW.quantity_cartons_closed := GREATEST(COALESCE(NEW.quantity_cartons_closed, 0), 0);
  NEW.quantity_units_loose    := GREATEST(COALESCE(NEW.quantity_units_loose, 0), 0);

  IF TG_OP = 'UPDATE' THEN
    -- La dimension qui a CHANGÉ fait foi
    IF NEW.quantity_cartons_closed IS DISTINCT FROM OLD.quantity_cartons_closed
       OR NEW.quantity_units_loose IS DISTINCT FROM OLD.quantity_units_loose THEN
      NEW.total_units := (NEW.quantity_cartons_closed * NEW.units_per_carton) + NEW.quantity_units_loose;

    ELSIF NEW.total_units IS DISTINCT FROM OLD.total_units THEN
      NEW.total_units             := GREATEST(COALESCE(NEW.total_units, 0), 0);
      NEW.quantity_cartons_closed := FLOOR(NEW.total_units / NEW.units_per_carton);
      NEW.quantity_units_loose    := MOD(NEW.total_units, NEW.units_per_carton);

    ELSIF NEW.quantity IS DISTINCT FROM OLD.quantity THEN
      -- Les RPC entrepôt écrivent ici → quantity autoritaire
      NEW.total_units             := GREATEST(COALESCE(NEW.quantity, 0), 0);
      NEW.quantity_cartons_closed := FLOOR(NEW.total_units / NEW.units_per_carton);
      NEW.quantity_units_loose    := MOD(NEW.total_units, NEW.units_per_carton);

    ELSE
      -- ni quantity ni total ni cartons changés (ex : units_per_carton/reserved)
      NEW.total_units := (NEW.quantity_cartons_closed * NEW.units_per_carton) + NEW.quantity_units_loose;
    END IF;

  ELSE
    -- INSERT : priorité cartons/unités, puis total_units, puis quantity
    IF NEW.quantity_cartons_closed > 0 OR NEW.quantity_units_loose > 0 THEN
      NEW.total_units := (NEW.quantity_cartons_closed * NEW.units_per_carton) + NEW.quantity_units_loose;
    ELSIF COALESCE(NEW.total_units, 0) > 0 THEN
      NEW.total_units             := NEW.total_units;
      NEW.quantity_cartons_closed := FLOOR(NEW.total_units / NEW.units_per_carton);
      NEW.quantity_units_loose    := MOD(NEW.total_units, NEW.units_per_carton);
    ELSE
      NEW.total_units             := GREATEST(COALESCE(NEW.quantity, 0), 0);
      NEW.quantity_cartons_closed := FLOOR(NEW.total_units / NEW.units_per_carton);
      NEW.quantity_units_loose    := MOD(NEW.total_units, NEW.units_per_carton);
    END IF;
  END IF;

  -- quantity = miroir de total_units (compat héritée) ; available = total − réservé
  NEW.quantity           := COALESCE(NEW.total_units, 0);
  NEW.available_quantity := GREATEST(COALESCE(NEW.total_units, 0) - COALESCE(NEW.reserved_quantity, 0), 0);
  RETURN NEW;
END;
$$;

-- Recréer le trigger (même périmètre de colonnes) — UNIQUEMENT si le modèle
-- cartons/unités existe (extension multi-entrepôts 20260409123000 appliquée).
-- Sinon ce fix n'a pas lieu d'être (pas de double modèle) → on saute.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'location_stock'
      AND column_name = 'units_per_carton'
  ) THEN
    DROP TRIGGER IF EXISTS trigger_sync_location_stock_units ON public.location_stock;
    CREATE TRIGGER trigger_sync_location_stock_units
      BEFORE INSERT OR UPDATE OF units_per_carton, quantity_cartons_closed, quantity_units_loose, total_units, quantity, reserved_quantity
      ON public.location_stock
      FOR EACH ROW
      EXECUTE FUNCTION public.sync_location_stock_units();
  ELSE
    RAISE NOTICE 'location_stock.units_per_carton absent → trigger non recréé (extension multi-entrepôts 20260409123000 non appliquée).';
  END IF;
END $$;
