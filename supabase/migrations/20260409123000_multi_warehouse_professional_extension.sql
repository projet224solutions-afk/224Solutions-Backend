-- =====================================================
-- EXTENSION PROFESSIONNELLE MULTI-ENTREPÔTS / MULTI-BOUTIQUES
-- 224SOLUTIONS - Avril 2026
-- =====================================================
-- Objectif:
--   * séparation stock entrepôt / stock boutique
--   * transfert multi-destinations (boutique, client, autre entrepôt)
--   * cartons + unités
--   * mapping obligatoire produit entrepôt -> produit boutique
--   * reçu PDF téléchargeable + audit complet + idempotency
-- Contraintes:
--   * ajout uniquement, zéro régression, rétrocompatibilité stricte
-- =====================================================

BEGIN;

-- -----------------------------------------------------
-- 1) STOCK PAR LIEU : CARTONS + UNITÉS
-- -----------------------------------------------------
ALTER TABLE public.location_stock
  ADD COLUMN IF NOT EXISTS units_per_carton INTEGER NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS quantity_cartons_closed INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS quantity_units_loose INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_units INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS stock_role TEXT NOT NULL DEFAULT 'warehouse',
  ADD COLUMN IF NOT EXISTS linked_shop_product_id UUID NULL REFERENCES public.products(id) ON DELETE SET NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'location_stock_stock_role_check'
  ) THEN
    ALTER TABLE public.location_stock
      ADD CONSTRAINT location_stock_stock_role_check
      CHECK (stock_role IN ('warehouse', 'shop'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_location_stock_total_units ON public.location_stock(total_units);
CREATE INDEX IF NOT EXISTS idx_location_stock_linked_shop_product ON public.location_stock(linked_shop_product_id);

-- -----------------------------------------------------
-- 2) MAPPING ENTREPÔT -> BOUTIQUE
-- -----------------------------------------------------
CREATE TABLE IF NOT EXISTS public.warehouse_shop_product_links (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  warehouse_product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  shop_product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  source_location_id UUID NULL REFERENCES public.vendor_locations(id) ON DELETE SET NULL,
  destination_location_id UUID NULL REFERENCES public.vendor_locations(id) ON DELETE SET NULL,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_by UUID NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (vendor_id, warehouse_product_id, shop_product_id)
);

CREATE INDEX IF NOT EXISTS idx_warehouse_shop_links_vendor ON public.warehouse_shop_product_links(vendor_id);
CREATE INDEX IF NOT EXISTS idx_warehouse_shop_links_source ON public.warehouse_shop_product_links(source_location_id);
CREATE INDEX IF NOT EXISTS idx_warehouse_shop_links_dest ON public.warehouse_shop_product_links(destination_location_id);

-- -----------------------------------------------------
-- 3) TRANSFERTS : DESTINATION INTELLIGENTE + WORKFLOW
-- -----------------------------------------------------
ALTER TABLE public.stock_transfers
  ADD COLUMN IF NOT EXISTS destination_type TEXT NOT NULL DEFAULT 'warehouse',
  ADD COLUMN IF NOT EXISTS destination_client_info JSONB NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS destination_shop_id UUID NULL REFERENCES public.vendor_locations(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS approval_status TEXT NOT NULL DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS approved_by UUID NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS approved_at TIMESTAMPTZ NULL,
  ADD COLUMN IF NOT EXISTS confirmed_at TIMESTAMPTZ NULL,
  ADD COLUMN IF NOT EXISTS receipt_url TEXT NULL,
  ADD COLUMN IF NOT EXISTS idempotency_key TEXT NULL,
  ADD COLUMN IF NOT EXISTS parent_transfer_id UUID NULL REFERENCES public.stock_transfers(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS transfer_mode TEXT NOT NULL DEFAULT 'units',
  ADD COLUMN IF NOT EXISTS audit_metadata JSONB NOT NULL DEFAULT '{}'::jsonb;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'stock_transfers_destination_type_check'
  ) THEN
    ALTER TABLE public.stock_transfers
      ADD CONSTRAINT stock_transfers_destination_type_check
      CHECK (destination_type IN ('warehouse', 'shop', 'client'));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'stock_transfers_approval_status_check'
  ) THEN
    ALTER TABLE public.stock_transfers
      ADD CONSTRAINT stock_transfers_approval_status_check
      CHECK (approval_status IN ('draft', 'pending', 'approved', 'confirmed', 'cancelled'));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'stock_transfers_transfer_mode_check'
  ) THEN
    ALTER TABLE public.stock_transfers
      ADD CONSTRAINT stock_transfers_transfer_mode_check
      CHECK (transfer_mode IN ('units', 'cartons', 'mixed'));
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS idx_stock_transfers_idempotency_key
  ON public.stock_transfers(idempotency_key)
  WHERE idempotency_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_stock_transfers_destination_type ON public.stock_transfers(destination_type);
CREATE INDEX IF NOT EXISTS idx_stock_transfers_approval_status ON public.stock_transfers(approval_status);
CREATE INDEX IF NOT EXISTS idx_stock_transfers_receipt_url ON public.stock_transfers(receipt_url);

ALTER TABLE public.stock_transfer_items
  ADD COLUMN IF NOT EXISTS quantity_cartons INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS quantity_units INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS units_per_carton INTEGER NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS total_units INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS shop_product_id UUID NULL REFERENCES public.products(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS stock_before_units INTEGER NULL,
  ADD COLUMN IF NOT EXISTS stock_after_units INTEGER NULL;

CREATE INDEX IF NOT EXISTS idx_stock_transfer_items_shop_product ON public.stock_transfer_items(shop_product_id);
CREATE INDEX IF NOT EXISTS idx_stock_transfer_items_total_units ON public.stock_transfer_items(total_units);

-- -----------------------------------------------------
-- 4) AUDIT LOG COMPLÉMENTAIRE (TRAÇABILITÉ FINE)
-- -----------------------------------------------------
CREATE TABLE IF NOT EXISTS public.warehouse_audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  entity_type TEXT NOT NULL,
  entity_id UUID NOT NULL,
  action TEXT NOT NULL,
  performed_by UUID NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  payload_before JSONB,
  payload_after JSONB,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_warehouse_audit_logs_vendor ON public.warehouse_audit_logs(vendor_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_warehouse_audit_logs_entity ON public.warehouse_audit_logs(entity_type, entity_id);

-- -----------------------------------------------------
-- 5) TRIGGERS : SYNCHRONISATION CARTONS/UNITÉS
-- -----------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_location_stock_units()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.units_per_carton := GREATEST(COALESCE(NEW.units_per_carton, 1), 1);
  NEW.quantity_cartons_closed := GREATEST(COALESCE(NEW.quantity_cartons_closed, 0), 0);
  NEW.quantity_units_loose := GREATEST(COALESCE(NEW.quantity_units_loose, 0), 0);

  IF COALESCE(NEW.total_units, 0) <= 0 AND COALESCE(NEW.quantity, 0) > 0 AND NEW.quantity_cartons_closed = 0 AND NEW.quantity_units_loose = 0 THEN
    NEW.total_units := COALESCE(NEW.quantity, 0);
  END IF;

  IF COALESCE(NEW.quantity_cartons_closed, 0) > 0 OR COALESCE(NEW.quantity_units_loose, 0) > 0 THEN
    NEW.total_units := (NEW.quantity_cartons_closed * NEW.units_per_carton) + NEW.quantity_units_loose;
  ELSE
    NEW.quantity_cartons_closed := FLOOR(COALESCE(NEW.total_units, 0) / NEW.units_per_carton);
    NEW.quantity_units_loose := MOD(COALESCE(NEW.total_units, 0), NEW.units_per_carton);
  END IF;

  NEW.quantity := COALESCE(NEW.total_units, 0);
  NEW.available_quantity := GREATEST(COALESCE(NEW.total_units, 0) - COALESCE(NEW.reserved_quantity, 0), 0);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_sync_location_stock_units ON public.location_stock;
CREATE TRIGGER trigger_sync_location_stock_units
  BEFORE INSERT OR UPDATE OF units_per_carton, quantity_cartons_closed, quantity_units_loose, total_units, quantity, reserved_quantity
  ON public.location_stock
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_location_stock_units();

CREATE OR REPLACE FUNCTION public.sync_stock_transfer_item_units()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.units_per_carton := GREATEST(COALESCE(NEW.units_per_carton, 1), 1);
  NEW.quantity_cartons := GREATEST(COALESCE(NEW.quantity_cartons, 0), 0);
  NEW.quantity_units := GREATEST(COALESCE(NEW.quantity_units, 0), 0);

  IF COALESCE(NEW.total_units, 0) <= 0 THEN
    IF NEW.quantity_cartons > 0 OR NEW.quantity_units > 0 THEN
      NEW.total_units := (NEW.quantity_cartons * NEW.units_per_carton) + NEW.quantity_units;
    ELSE
      NEW.total_units := GREATEST(COALESCE(NEW.quantity_sent, 0), 0);
      NEW.quantity_cartons := FLOOR(COALESCE(NEW.total_units, 0) / NEW.units_per_carton);
      NEW.quantity_units := MOD(COALESCE(NEW.total_units, 0), NEW.units_per_carton);
    END IF;
  END IF;

  NEW.quantity_sent := GREATEST(COALESCE(NEW.total_units, 0), 0);
  NEW.quantity_lost := GREATEST(COALESCE(NEW.quantity_sent, 0) - COALESCE(NEW.quantity_received, 0), 0);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_sync_stock_transfer_item_units ON public.stock_transfer_items;
CREATE TRIGGER trigger_sync_stock_transfer_item_units
  BEFORE INSERT OR UPDATE OF quantity_cartons, quantity_units, units_per_carton, total_units, quantity_sent, quantity_received
  ON public.stock_transfer_items
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_stock_transfer_item_units();

-- Backfill de toutes les lignes existantes pour garder la compatibilité
UPDATE public.location_stock
SET units_per_carton = GREATEST(COALESCE(units_per_carton, 1), 1),
    total_units = CASE
      WHEN COALESCE(total_units, 0) > 0 THEN total_units
      ELSE COALESCE(quantity, 0)
    END,
    quantity_cartons_closed = CASE
      WHEN COALESCE(quantity_cartons_closed, 0) > 0 THEN quantity_cartons_closed
      ELSE FLOOR(COALESCE(CASE WHEN total_units > 0 THEN total_units ELSE quantity END, 0) / GREATEST(COALESCE(units_per_carton, 1), 1))
    END,
    quantity_units_loose = CASE
      WHEN COALESCE(quantity_cartons_closed, 0) > 0 OR COALESCE(quantity_units_loose, 0) > 0 THEN quantity_units_loose
      ELSE MOD(COALESCE(CASE WHEN total_units > 0 THEN total_units ELSE quantity END, 0), GREATEST(COALESCE(units_per_carton, 1), 1))
    END;

-- -----------------------------------------------------
-- 6) AUDIT LOG TRIGGER GÉNÉRIQUE
-- -----------------------------------------------------
CREATE OR REPLACE FUNCTION public.log_warehouse_audit_event()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_payload JSONB := COALESCE(to_jsonb(NEW), to_jsonb(OLD));
  v_vendor_id UUID;
  v_entity_id UUID;
BEGIN
  BEGIN
    v_vendor_id := NULLIF(v_payload->>'vendor_id', '')::UUID;
  EXCEPTION WHEN others THEN
    v_vendor_id := NULL;
  END;

  BEGIN
    v_entity_id := NULLIF(v_payload->>'id', '')::UUID;
  EXCEPTION WHEN others THEN
    v_entity_id := gen_random_uuid();
  END;

  IF v_vendor_id IS NULL AND v_payload ? 'location_id' THEN
    SELECT vendor_id INTO v_vendor_id
    FROM public.vendor_locations
    WHERE id = NULLIF(v_payload->>'location_id', '')::UUID;
  END IF;

  IF v_vendor_id IS NULL AND v_payload ? 'source_location_id' THEN
    SELECT vendor_id INTO v_vendor_id
    FROM public.vendor_locations
    WHERE id = NULLIF(v_payload->>'source_location_id', '')::UUID;
  END IF;

  IF v_vendor_id IS NULL AND v_payload ? 'destination_location_id' THEN
    SELECT vendor_id INTO v_vendor_id
    FROM public.vendor_locations
    WHERE id = NULLIF(v_payload->>'destination_location_id', '')::UUID;
  END IF;

  IF v_vendor_id IS NULL THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  INSERT INTO public.warehouse_audit_logs (
    vendor_id,
    entity_type,
    entity_id,
    action,
    performed_by,
    payload_before,
    payload_after,
    metadata
  ) VALUES (
    v_vendor_id,
    TG_TABLE_NAME,
    v_entity_id,
    TG_OP,
    COALESCE(NULLIF(v_payload->>'created_by', '')::UUID, NULLIF(v_payload->>'confirmed_by', '')::UUID, NULLIF(v_payload->>'received_by', '')::UUID),
    CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE to_jsonb(OLD) END,
    CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE to_jsonb(NEW) END,
    jsonb_build_object('trigger', TG_NAME)
  );

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trigger_audit_stock_transfers ON public.stock_transfers;
CREATE TRIGGER trigger_audit_stock_transfers
  AFTER INSERT OR UPDATE OR DELETE ON public.stock_transfers
  FOR EACH ROW EXECUTE FUNCTION public.log_warehouse_audit_event();

DROP TRIGGER IF EXISTS trigger_audit_stock_transfer_items ON public.stock_transfer_items;
CREATE TRIGGER trigger_audit_stock_transfer_items
  AFTER INSERT OR UPDATE OR DELETE ON public.stock_transfer_items
  FOR EACH ROW EXECUTE FUNCTION public.log_warehouse_audit_event();

DROP TRIGGER IF EXISTS trigger_audit_location_stock ON public.location_stock;
CREATE TRIGGER trigger_audit_location_stock
  AFTER INSERT OR UPDATE OR DELETE ON public.location_stock
  FOR EACH ROW EXECUTE FUNCTION public.log_warehouse_audit_event();

DROP TRIGGER IF EXISTS trigger_audit_warehouse_shop_product_links ON public.warehouse_shop_product_links;
CREATE TRIGGER trigger_audit_warehouse_shop_product_links
  AFTER INSERT OR UPDATE OR DELETE ON public.warehouse_shop_product_links
  FOR EACH ROW EXECUTE FUNCTION public.log_warehouse_audit_event();

-- -----------------------------------------------------
-- 7) RPC : CRÉATION D'UN TRANSFERT AVANCÉ
-- -----------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_advanced_stock_transfer(
  p_vendor_id UUID,
  p_source_location_id UUID,
  p_destination_type TEXT,
  p_destination_location_id UUID DEFAULT NULL,
  p_destination_client_info JSONB DEFAULT '{}'::JSONB,
  p_items JSONB DEFAULT '[]'::JSONB,
  p_notes TEXT DEFAULT NULL,
  p_created_by UUID DEFAULT NULL,
  p_expected_arrival TIMESTAMPTZ DEFAULT NULL,
  p_idempotency_key TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_transfer_id UUID;
  v_transfer_number TEXT;
  v_item JSONB;
  v_total_units INTEGER := 0;
  v_total_items INTEGER := 0;
  v_units_per_carton INTEGER;
  v_item_units INTEGER;
  v_stock_total INTEGER;
  v_shop_product_id UUID;
BEGIN
  IF COALESCE(JSONB_ARRAY_LENGTH(p_items), 0) = 0 THEN
    RAISE EXCEPTION 'Aucun article à transférer';
  END IF;

  IF p_idempotency_key IS NOT NULL THEN
    SELECT id INTO v_transfer_id
    FROM public.stock_transfers
    WHERE idempotency_key = p_idempotency_key
    LIMIT 1;

    IF v_transfer_id IS NOT NULL THEN
      RETURN v_transfer_id;
    END IF;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.vendor_locations
    WHERE id = p_source_location_id
      AND vendor_id = p_vendor_id
      AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'Lieu source invalide';
  END IF;

  IF p_destination_type NOT IN ('warehouse', 'shop', 'client') THEN
    RAISE EXCEPTION 'Type de destination invalide';
  END IF;

  IF p_destination_type IN ('warehouse', 'shop') THEN
    IF p_destination_location_id IS NULL THEN
      RAISE EXCEPTION 'La destination est obligatoire pour ce type de transfert';
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM public.vendor_locations
      WHERE id = p_destination_location_id
        AND vendor_id = p_vendor_id
        AND is_active = TRUE
    ) THEN
      RAISE EXCEPTION 'Lieu destination invalide';
    END IF;

    IF p_destination_location_id = p_source_location_id THEN
      RAISE EXCEPTION 'La source et la destination doivent être différentes';
    END IF;
  END IF;

  IF p_destination_type = 'client'
     AND COALESCE(BTRIM(COALESCE(p_destination_client_info->>'name', '')), '') = ''
     AND COALESCE(BTRIM(COALESCE(p_destination_client_info->>'phone', '')), '') = '' THEN
    RAISE EXCEPTION 'Les informations du client sont obligatoires';
  END IF;

  v_transfer_number := public.generate_transfer_number(p_vendor_id);

  INSERT INTO public.stock_transfers (
    vendor_id,
    transfer_number,
    source_location_id,
    destination_location_id,
    destination_type,
    destination_client_info,
    destination_shop_id,
    status,
    approval_status,
    notes,
    created_by,
    expected_arrival_at,
    idempotency_key,
    transfer_mode,
    receipt_url,
    audit_metadata
  ) VALUES (
    p_vendor_id,
    v_transfer_number,
    p_source_location_id,
    p_destination_location_id,
    p_destination_type,
    COALESCE(p_destination_client_info, '{}'::JSONB),
    CASE WHEN p_destination_type = 'shop' THEN p_destination_location_id ELSE NULL END,
    'pending',
    'approved',
    p_notes,
    p_created_by,
    p_expected_arrival,
    p_idempotency_key,
    'units',
    'generated://transfer/' || v_transfer_number,
    jsonb_build_object('workflow', 'multi-warehouse-professional', 'version', '2026.04')
  )
  RETURNING id INTO v_transfer_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_units_per_carton := GREATEST(COALESCE((v_item->>'units_per_carton')::INTEGER, 1), 1);
    v_item_units := COALESCE(
      (v_item->>'total_units')::INTEGER,
      (COALESCE((v_item->>'quantity_cartons')::INTEGER, 0) * v_units_per_carton)
      + COALESCE((v_item->>'quantity_units')::INTEGER, COALESCE((v_item->>'quantity')::INTEGER, 0))
    );

    IF COALESCE(v_item_units, 0) <= 0 THEN
      RAISE EXCEPTION 'La quantité doit être supérieure à zéro';
    END IF;

    SELECT COALESCE(total_units, quantity, 0)
      INTO v_stock_total
    FROM public.location_stock
    WHERE location_id = p_source_location_id
      AND product_id = (v_item->>'product_id')::UUID
    FOR UPDATE;

    IF v_stock_total IS NULL THEN
      RAISE EXCEPTION 'Produit source introuvable dans le stock entrepôt';
    END IF;

    IF v_stock_total < v_item_units THEN
      RAISE EXCEPTION 'Stock insuffisant pour le produit % (disponible: %, demandé: %)',
        (v_item->>'product_id'), v_stock_total, v_item_units;
    END IF;

    v_shop_product_id := NULLIF(v_item->>'shop_product_id', '')::UUID;

    IF p_destination_type = 'shop' AND v_shop_product_id IS NULL THEN
      v_shop_product_id := (v_item->>'product_id')::UUID;
    END IF;

    IF p_destination_type = 'shop' THEN
      INSERT INTO public.warehouse_shop_product_links (
        vendor_id,
        warehouse_product_id,
        shop_product_id,
        source_location_id,
        destination_location_id,
        is_active,
        metadata,
        created_by
      ) VALUES (
        p_vendor_id,
        (v_item->>'product_id')::UUID,
        v_shop_product_id,
        p_source_location_id,
        p_destination_location_id,
        TRUE,
        jsonb_build_object('auto_created', TRUE, 'from_transfer', v_transfer_id),
        p_created_by
      )
      ON CONFLICT (vendor_id, warehouse_product_id, shop_product_id)
      DO UPDATE SET
        is_active = TRUE,
        destination_location_id = EXCLUDED.destination_location_id,
        updated_at = NOW();
    END IF;

    INSERT INTO public.stock_transfer_items (
      transfer_id,
      product_id,
      quantity_sent,
      quantity_received,
      quantity_lost,
      quantity_cartons,
      quantity_units,
      units_per_carton,
      total_units,
      shop_product_id,
      stock_before_units,
      stock_after_units,
      notes
    ) VALUES (
      v_transfer_id,
      (v_item->>'product_id')::UUID,
      v_item_units,
      0,
      0,
      COALESCE((v_item->>'quantity_cartons')::INTEGER, 0),
      COALESCE((v_item->>'quantity_units')::INTEGER, COALESCE((v_item->>'quantity')::INTEGER, 0)),
      v_units_per_carton,
      v_item_units,
      v_shop_product_id,
      v_stock_total,
      GREATEST(v_stock_total - v_item_units, 0),
      COALESCE(v_item->>'notes', p_notes)
    );

    v_total_units := v_total_units + v_item_units;
    v_total_items := v_total_items + 1;
  END LOOP;

  UPDATE public.stock_transfers
  SET total_items = v_total_items,
      total_quantity_sent = v_total_units,
      transfer_mode = CASE
        WHEN EXISTS (
          SELECT 1 FROM public.stock_transfer_items
          WHERE transfer_id = v_transfer_id
            AND COALESCE(quantity_cartons, 0) > 0
            AND COALESCE(quantity_units, 0) > 0
        ) THEN 'mixed'
        WHEN EXISTS (
          SELECT 1 FROM public.stock_transfer_items
          WHERE transfer_id = v_transfer_id
            AND COALESCE(quantity_cartons, 0) > 0
        ) THEN 'cartons'
        ELSE 'units'
      END,
      approved_by = COALESCE(approved_by, p_created_by),
      approved_at = COALESCE(approved_at, NOW())
  WHERE id = v_transfer_id;

  RETURN v_transfer_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_advanced_stock_transfer(UUID, UUID, TEXT, UUID, JSONB, JSONB, TEXT, UUID, TIMESTAMPTZ, TEXT)
TO authenticated;

COMMENT ON FUNCTION public.create_advanced_stock_transfer(UUID, UUID, TEXT, UUID, JSONB, JSONB, TEXT, UUID, TIMESTAMPTZ, TEXT)
IS 'Crée un transfert multi-destination rétrocompatible avec gestion cartons + unités et liaison boutique';

COMMIT;
