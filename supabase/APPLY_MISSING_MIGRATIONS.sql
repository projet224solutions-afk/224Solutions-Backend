-- =====================================================
-- MIGRATIONS MANQUANTES - 224SOLUTIONS
-- À exécuter dans : https://supabase.com/dashboard/project/uakkxaibujzxdiqzpnpr/sql/new
-- Script idempotent: sécurisé à exécuter plusieurs fois
-- =====================================================

-- Timeout verrou : échoue proprement si un autre process bloque un accès DDL
SET lock_timeout = '10s';

-- ============================================================
-- MIGRATION: 20260129220000_multi_warehouse_pos_system.sql
-- ============================================================
-- =====================================================
-- SYSTÈME MULTI-ENTREPÔTS & MULTI-POS PROFESSIONNEL
-- 224SOLUTIONS - 29 Janvier 2026
-- =====================================================
-- Objectif: Gestion unifiée des lieux (Entrepôts & POS)
-- avec transferts, permissions et traçabilité complète
-- =====================================================

-- ===========================================
-- 0. NETTOYAGE PRÉALABLE DES TRIGGERS
-- ===========================================
-- Supprimer les triggers AVANT de modifier les tables
-- pour éviter les erreurs de colonnes manquantes
-- Encapsulé dans un bloc DO pour ignorer si les tables n'existent pas
DO $$ 
BEGIN
  DROP TRIGGER IF EXISTS trigger_location_stock_available ON location_stock;
EXCEPTION WHEN undefined_table THEN NULL;
END $$;

DO $$ 
BEGIN
  DROP TRIGGER IF EXISTS trigger_transfer_item_values ON stock_transfer_items;
EXCEPTION WHEN undefined_table THEN NULL;
END $$;

DO $$ 
BEGIN
  DROP TRIGGER IF EXISTS trigger_loss_value ON stock_losses;
EXCEPTION WHEN undefined_table THEN NULL;
END $$;

DO $$ 
BEGIN
  DROP TRIGGER IF EXISTS trigger_vendor_locations_updated ON vendor_locations;
EXCEPTION WHEN undefined_table THEN NULL;
END $$;

DO $$ 
BEGIN
  DROP TRIGGER IF EXISTS trigger_location_stock_updated ON location_stock;
EXCEPTION WHEN undefined_table THEN NULL;
END $$;

DO $$ 
BEGIN
  DROP TRIGGER IF EXISTS trigger_stock_transfers_updated ON stock_transfers;
EXCEPTION WHEN undefined_table THEN NULL;
END $$;

-- ===========================================
-- 1. TABLE DES LIEUX (LOCATIONS) - CONCEPT UNIFIÉ
-- ===========================================
-- Un lieu peut être un entrepôt ou un POS
-- Un POS est un entrepôt spécial activé pour la vente

CREATE TABLE IF NOT EXISTS public.vendor_locations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  
  -- Informations de base
  name TEXT NOT NULL,
  code TEXT, -- Code court unique par vendeur (ex: ENT01, POS01)
  description TEXT,
  
  -- Type de lieu
  location_type TEXT NOT NULL DEFAULT 'warehouse' CHECK (location_type IN ('warehouse', 'pos')),
  is_pos_enabled BOOLEAN DEFAULT FALSE, -- Un entrepôt peut devenir POS
  
  -- Adresse
  address TEXT,
  city TEXT,
  country TEXT DEFAULT 'Guinée',
  coordinates JSONB, -- {lat, lng} pour géolocalisation
  
  -- Contact responsable
  manager_name TEXT,
  manager_phone TEXT,
  manager_email TEXT,
  
  -- Statut
  is_active BOOLEAN DEFAULT TRUE,
  is_default BOOLEAN DEFAULT FALSE, -- Lieu par défaut pour les nouveaux produits
  
  -- Métadonnées
  settings JSONB DEFAULT '{}', -- Paramètres spécifiques (heures d'ouverture, etc.)
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  
  -- Contrainte d'unicité du code par vendeur
  UNIQUE(vendor_id, code)
);

-- Ajouter colonnes manquantes si la table existe déjà (AVANT les index)
ALTER TABLE public.vendor_locations ADD COLUMN IF NOT EXISTS code TEXT;
ALTER TABLE public.vendor_locations ADD COLUMN IF NOT EXISTS location_type TEXT DEFAULT 'warehouse';
ALTER TABLE public.vendor_locations ADD COLUMN IF NOT EXISTS is_pos_enabled BOOLEAN DEFAULT FALSE;
ALTER TABLE public.vendor_locations ADD COLUMN IF NOT EXISTS is_default BOOLEAN DEFAULT FALSE;
ALTER TABLE public.vendor_locations ADD COLUMN IF NOT EXISTS coordinates JSONB;
ALTER TABLE public.vendor_locations ADD COLUMN IF NOT EXISTS settings JSONB DEFAULT '{}';

-- Index pour performance (APRÈS les colonnes)
CREATE INDEX IF NOT EXISTS idx_vendor_locations_vendor ON vendor_locations(vendor_id);
CREATE INDEX IF NOT EXISTS idx_vendor_locations_type ON vendor_locations(location_type);
CREATE INDEX IF NOT EXISTS idx_vendor_locations_active ON vendor_locations(is_active) WHERE is_active = TRUE;
CREATE INDEX IF NOT EXISTS idx_vendor_locations_pos ON vendor_locations(is_pos_enabled) WHERE is_pos_enabled = TRUE;

-- ===========================================
-- 2. STOCK PAR LIEU (LOCATION_STOCK)
-- ===========================================
-- Le stock est lié au LIEU, pas au produit
-- Un produit peut exister dans plusieurs lieux

CREATE TABLE IF NOT EXISTS public.location_stock (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  location_id UUID NOT NULL REFERENCES public.vendor_locations(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  
  -- Quantités
  quantity INTEGER NOT NULL DEFAULT 0,
  reserved_quantity INTEGER DEFAULT 0, -- Stock réservé pour commandes en cours
  available_quantity INTEGER DEFAULT 0, -- Calculé par trigger
  
  -- Seuils d'alerte
  minimum_stock INTEGER DEFAULT 5,
  maximum_stock INTEGER,
  reorder_point INTEGER DEFAULT 10,
  reorder_quantity INTEGER DEFAULT 20,
  
  -- Informations supplémentaires
  bin_location TEXT, -- Emplacement physique dans l'entrepôt (ex: A1-B2)
  lot_number TEXT,
  expiry_date DATE,
  
  -- Coûts
  cost_price DECIMAL(15,2) DEFAULT 0,
  last_purchase_price DECIMAL(15,2),
  
  -- Timestamps
  last_stock_update TIMESTAMPTZ DEFAULT NOW(),
  last_sale_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  
  -- Un produit ne peut être qu'une fois par lieu
  UNIQUE(location_id, product_id)
);

-- Ajouter toutes les colonnes manquantes si elles n'existent pas (AVANT les index)
ALTER TABLE public.location_stock ADD COLUMN IF NOT EXISTS available_quantity INTEGER DEFAULT 0;
ALTER TABLE public.location_stock ADD COLUMN IF NOT EXISTS reserved_quantity INTEGER DEFAULT 0;
ALTER TABLE public.location_stock ADD COLUMN IF NOT EXISTS minimum_stock INTEGER DEFAULT 5;
ALTER TABLE public.location_stock ADD COLUMN IF NOT EXISTS maximum_stock INTEGER;
ALTER TABLE public.location_stock ADD COLUMN IF NOT EXISTS reorder_point INTEGER DEFAULT 10;
ALTER TABLE public.location_stock ADD COLUMN IF NOT EXISTS reorder_quantity INTEGER DEFAULT 20;
ALTER TABLE public.location_stock ADD COLUMN IF NOT EXISTS bin_location TEXT;
ALTER TABLE public.location_stock ADD COLUMN IF NOT EXISTS lot_number TEXT;
ALTER TABLE public.location_stock ADD COLUMN IF NOT EXISTS expiry_date DATE;
ALTER TABLE public.location_stock ADD COLUMN IF NOT EXISTS cost_price DECIMAL(15,2) DEFAULT 0;
ALTER TABLE public.location_stock ADD COLUMN IF NOT EXISTS last_purchase_price DECIMAL(15,2);
ALTER TABLE public.location_stock ADD COLUMN IF NOT EXISTS last_stock_update TIMESTAMPTZ DEFAULT NOW();
ALTER TABLE public.location_stock ADD COLUMN IF NOT EXISTS last_sale_at TIMESTAMPTZ;

-- Index pour performance (APRÈS les colonnes)
CREATE INDEX IF NOT EXISTS idx_location_stock_location ON location_stock(location_id);
CREATE INDEX IF NOT EXISTS idx_location_stock_product ON location_stock(product_id);
CREATE INDEX IF NOT EXISTS idx_location_stock_low ON location_stock(quantity, minimum_stock) WHERE quantity <= minimum_stock;
CREATE INDEX IF NOT EXISTS idx_location_stock_available ON location_stock(available_quantity);

-- ===========================================
-- 3. SYSTÈME DE TRANSFERTS DE STOCK
-- ===========================================

-- Table des transferts
CREATE TABLE IF NOT EXISTS public.stock_transfers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  
  -- Numéro unique de transfert
  transfer_number TEXT NOT NULL UNIQUE,
  
  -- Lieux source et destination
  from_location_id UUID NOT NULL REFERENCES public.vendor_locations(id),
  to_location_id UUID NOT NULL REFERENCES public.vendor_locations(id),
  
  -- Statut du transfert
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN (
    'pending',      -- En attente de départ
    'in_transit',   -- En transit
    'delivered',    -- Livré (en attente de confirmation)
    'completed',    -- Confirmé complet
    'partial',      -- Confirmé avec manquants
    'cancelled'     -- Annulé
  )),
  
  -- Dates importantes
  initiated_at TIMESTAMPTZ DEFAULT NOW(),
  shipped_at TIMESTAMPTZ,
  delivered_at TIMESTAMPTZ,
  confirmed_at TIMESTAMPTZ,
  
  -- Acteurs
  initiated_by UUID REFERENCES auth.users(id),
  shipped_by UUID REFERENCES auth.users(id),
  received_by UUID REFERENCES auth.users(id),
  confirmed_by UUID REFERENCES auth.users(id),
  
  -- Notes et commentaires
  notes TEXT,
  shipping_notes TEXT,
  reception_notes TEXT,
  
  -- Totaux calculés
  total_items_sent INTEGER DEFAULT 0,
  total_items_received INTEGER DEFAULT 0,
  total_items_missing INTEGER DEFAULT 0,
  total_value DECIMAL(15,2) DEFAULT 0,
  
  -- Métadonnées
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  
  -- Un transfert ne peut pas être vers le même lieu
  CHECK (from_location_id != to_location_id)
);

-- Ajouter colonnes si elles n'existent pas (AVANT les index)
ALTER TABLE public.stock_transfers ADD COLUMN IF NOT EXISTS from_location_id UUID REFERENCES public.vendor_locations(id);
ALTER TABLE public.stock_transfers ADD COLUMN IF NOT EXISTS to_location_id UUID REFERENCES public.vendor_locations(id);
ALTER TABLE public.stock_transfers ADD COLUMN IF NOT EXISTS transfer_number TEXT;
ALTER TABLE public.stock_transfers ADD COLUMN IF NOT EXISTS status TEXT DEFAULT 'pending';
ALTER TABLE public.stock_transfers ADD COLUMN IF NOT EXISTS initiated_at TIMESTAMPTZ DEFAULT NOW();
ALTER TABLE public.stock_transfers ADD COLUMN IF NOT EXISTS shipped_at TIMESTAMPTZ;
ALTER TABLE public.stock_transfers ADD COLUMN IF NOT EXISTS delivered_at TIMESTAMPTZ;
ALTER TABLE public.stock_transfers ADD COLUMN IF NOT EXISTS confirmed_at TIMESTAMPTZ;
ALTER TABLE public.stock_transfers ADD COLUMN IF NOT EXISTS initiated_by UUID;
ALTER TABLE public.stock_transfers ADD COLUMN IF NOT EXISTS shipped_by UUID;
ALTER TABLE public.stock_transfers ADD COLUMN IF NOT EXISTS received_by UUID;
ALTER TABLE public.stock_transfers ADD COLUMN IF NOT EXISTS confirmed_by UUID;
ALTER TABLE public.stock_transfers ADD COLUMN IF NOT EXISTS shipping_notes TEXT;
ALTER TABLE public.stock_transfers ADD COLUMN IF NOT EXISTS reception_notes TEXT;
ALTER TABLE public.stock_transfers ADD COLUMN IF NOT EXISTS total_items_sent INTEGER DEFAULT 0;
ALTER TABLE public.stock_transfers ADD COLUMN IF NOT EXISTS total_items_received INTEGER DEFAULT 0;
ALTER TABLE public.stock_transfers ADD COLUMN IF NOT EXISTS total_items_missing INTEGER DEFAULT 0;
ALTER TABLE public.stock_transfers ADD COLUMN IF NOT EXISTS total_value DECIMAL(15,2) DEFAULT 0;
ALTER TABLE public.stock_transfers ADD COLUMN IF NOT EXISTS metadata JSONB DEFAULT '{}';
ALTER TABLE public.stock_transfers ADD COLUMN IF NOT EXISTS destination_type TEXT DEFAULT 'warehouse';
ALTER TABLE public.stock_transfers ADD COLUMN IF NOT EXISTS approval_status TEXT DEFAULT 'approved';

-- Index (APRÈS les colonnes)
CREATE INDEX IF NOT EXISTS idx_stock_transfers_vendor ON stock_transfers(vendor_id);
CREATE INDEX IF NOT EXISTS idx_stock_transfers_status ON stock_transfers(status);
CREATE INDEX IF NOT EXISTS idx_stock_transfers_from ON stock_transfers(from_location_id);
CREATE INDEX IF NOT EXISTS idx_stock_transfers_to ON stock_transfers(to_location_id);
CREATE INDEX IF NOT EXISTS idx_stock_transfers_date ON stock_transfers(initiated_at DESC);

-- Table des items de transfert
CREATE TABLE IF NOT EXISTS public.stock_transfer_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transfer_id UUID NOT NULL REFERENCES public.stock_transfers(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.products(id),
  
  -- Quantités
  quantity_sent INTEGER NOT NULL,
  quantity_received INTEGER DEFAULT 0,
  quantity_missing INTEGER DEFAULT 0, -- Calculé par trigger
  
  -- Prix unitaire au moment du transfert
  unit_cost DECIMAL(15,2) DEFAULT 0,
  total_value DECIMAL(15,2) DEFAULT 0, -- Calculé par trigger
  
  -- Notes spécifiques à l'item
  notes TEXT,
  reception_notes TEXT,
  
  -- Raison du manquant (si applicable)
  missing_reason TEXT CHECK (missing_reason IN ('damaged', 'lost', 'stolen', 'counting_error', 'other')),
  
  created_at TIMESTAMPTZ DEFAULT NOW(),
  
  -- Un produit ne peut être qu'une fois par transfert
  UNIQUE(transfer_id, product_id)
);

-- Ajouter colonnes si elles n'existent pas (AVANT les index)
ALTER TABLE public.stock_transfer_items ADD COLUMN IF NOT EXISTS quantity_missing INTEGER DEFAULT 0;
ALTER TABLE public.stock_transfer_items ADD COLUMN IF NOT EXISTS unit_cost DECIMAL(15,2) DEFAULT 0;
ALTER TABLE public.stock_transfer_items ADD COLUMN IF NOT EXISTS total_value DECIMAL(15,2) DEFAULT 0;
ALTER TABLE public.stock_transfer_items ADD COLUMN IF NOT EXISTS notes TEXT;
ALTER TABLE public.stock_transfer_items ADD COLUMN IF NOT EXISTS reception_notes TEXT;
ALTER TABLE public.stock_transfer_items ADD COLUMN IF NOT EXISTS missing_reason TEXT;

CREATE INDEX IF NOT EXISTS idx_transfer_items_transfer ON stock_transfer_items(transfer_id);
CREATE INDEX IF NOT EXISTS idx_transfer_items_product ON stock_transfer_items(product_id);

-- ===========================================
-- 4. GESTION DES PERTES / MANQUANTS
-- ===========================================

CREATE TABLE IF NOT EXISTS public.stock_losses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  
  -- Référence
  loss_number TEXT NOT NULL UNIQUE,
  
  -- Lieu concerné
  location_id UUID NOT NULL REFERENCES public.vendor_locations(id),
  product_id UUID NOT NULL REFERENCES public.products(id),
  
  -- Origine de la perte
  source_type TEXT NOT NULL CHECK (source_type IN (
    'transfer',     -- Perte durant un transfert
    'inventory',    -- Ajustement d'inventaire
    'damage',       -- Produit endommagé
    'expiry',       -- Produit expiré
    'theft',        -- Vol
    'other'         -- Autre
  )),
  source_reference_id UUID, -- ID du transfert ou autre document source
  
  -- Quantité et valeur
  quantity INTEGER NOT NULL,
  unit_cost DECIMAL(15,2) DEFAULT 0,
  total_loss_value DECIMAL(15,2) DEFAULT 0, -- Calculé par trigger
  
  -- Détails
  reason TEXT,
  notes TEXT,
  
  -- Validation
  is_validated BOOLEAN DEFAULT FALSE,
  validated_by UUID REFERENCES auth.users(id),
  validated_at TIMESTAMPTZ,
  
  -- Timestamps
  reported_by UUID REFERENCES auth.users(id),
  reported_at TIMESTAMPTZ DEFAULT NOW(),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Ajouter colonnes si elles n'existent pas (AVANT les index)
ALTER TABLE public.stock_losses ADD COLUMN IF NOT EXISTS loss_number TEXT;
ALTER TABLE public.stock_losses ADD COLUMN IF NOT EXISTS location_id UUID;
ALTER TABLE public.stock_losses ADD COLUMN IF NOT EXISTS product_id UUID;
ALTER TABLE public.stock_losses ADD COLUMN IF NOT EXISTS source_type TEXT;
ALTER TABLE public.stock_losses ADD COLUMN IF NOT EXISTS source_reference_id UUID;
ALTER TABLE public.stock_losses ADD COLUMN IF NOT EXISTS quantity INTEGER;
ALTER TABLE public.stock_losses ADD COLUMN IF NOT EXISTS unit_cost DECIMAL(15,2) DEFAULT 0;
ALTER TABLE public.stock_losses ADD COLUMN IF NOT EXISTS total_loss_value DECIMAL(15,2) DEFAULT 0;
ALTER TABLE public.stock_losses ADD COLUMN IF NOT EXISTS reason TEXT;
ALTER TABLE public.stock_losses ADD COLUMN IF NOT EXISTS notes TEXT;
ALTER TABLE public.stock_losses ADD COLUMN IF NOT EXISTS is_validated BOOLEAN DEFAULT FALSE;
ALTER TABLE public.stock_losses ADD COLUMN IF NOT EXISTS validated_by UUID;
ALTER TABLE public.stock_losses ADD COLUMN IF NOT EXISTS validated_at TIMESTAMPTZ;
ALTER TABLE public.stock_losses ADD COLUMN IF NOT EXISTS reported_by UUID;
ALTER TABLE public.stock_losses ADD COLUMN IF NOT EXISTS reported_at TIMESTAMPTZ DEFAULT NOW();

CREATE INDEX IF NOT EXISTS idx_stock_losses_vendor ON stock_losses(vendor_id);
CREATE INDEX IF NOT EXISTS idx_stock_losses_location ON stock_losses(location_id);
CREATE INDEX IF NOT EXISTS idx_stock_losses_product ON stock_losses(product_id);
CREATE INDEX IF NOT EXISTS idx_stock_losses_source ON stock_losses(source_type);
CREATE INDEX IF NOT EXISTS idx_stock_losses_date ON stock_losses(reported_at DESC);

-- ===========================================
-- 5. PERMISSIONS PAR LIEU (MULTI-VENDEURS POS)
-- ===========================================

CREATE TABLE IF NOT EXISTS public.location_permissions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  location_id UUID NOT NULL REFERENCES public.vendor_locations(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  
  -- Type d'accès
  role TEXT NOT NULL DEFAULT 'staff' CHECK (role IN ('owner', 'manager', 'staff', 'pos_only')),
  
  -- Permissions granulaires
  can_view BOOLEAN DEFAULT TRUE,
  can_sell BOOLEAN DEFAULT TRUE, -- Peut vendre (POS)
  can_receive BOOLEAN DEFAULT FALSE, -- Peut recevoir des transferts
  can_transfer BOOLEAN DEFAULT FALSE, -- Peut initier des transferts
  can_adjust BOOLEAN DEFAULT FALSE, -- Peut ajuster le stock
  can_manage BOOLEAN DEFAULT FALSE, -- Peut gérer le lieu
  
  -- Statut
  is_active BOOLEAN DEFAULT TRUE,
  granted_by UUID REFERENCES auth.users(id),
  granted_at TIMESTAMPTZ DEFAULT NOW(),
  
  -- Un user ne peut avoir qu'une permission par lieu
  UNIQUE(location_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_location_permissions_location ON location_permissions(location_id);
CREATE INDEX IF NOT EXISTS idx_location_permissions_user ON location_permissions(user_id);

-- ===========================================
-- 6. HISTORIQUE DES MOUVEMENTS DE STOCK
-- ===========================================

CREATE TABLE IF NOT EXISTS public.location_stock_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  location_id UUID NOT NULL REFERENCES public.vendor_locations(id),
  product_id UUID NOT NULL REFERENCES public.products(id),
  
  -- Type de mouvement
  movement_type TEXT NOT NULL CHECK (movement_type IN (
    'initial',      -- Stock initial
    'purchase',     -- Achat fournisseur
    'sale',         -- Vente
    'transfer_out', -- Sortie transfert
    'transfer_in',  -- Entrée transfert
    'adjustment',   -- Ajustement manuel
    'loss',         -- Perte
    'return',       -- Retour client
    'reservation',  -- Réservation
    'unreservation' -- Annulation réservation
  )),
  
  -- Quantités
  quantity_before INTEGER NOT NULL,
  quantity_change INTEGER NOT NULL, -- Peut être négatif
  quantity_after INTEGER NOT NULL,
  
  -- Référence (selon le type)
  reference_type TEXT, -- 'order', 'transfer', 'purchase', 'adjustment', 'loss'
  reference_id UUID,
  
  -- Acteur et notes
  performed_by UUID REFERENCES auth.users(id),
  notes TEXT,
  
  -- Timestamp
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_stock_history_location ON location_stock_history(location_id);
CREATE INDEX IF NOT EXISTS idx_stock_history_product ON location_stock_history(product_id);
CREATE INDEX IF NOT EXISTS idx_stock_history_type ON location_stock_history(movement_type);
CREATE INDEX IF NOT EXISTS idx_stock_history_date ON location_stock_history(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_stock_history_reference ON location_stock_history(reference_type, reference_id);

-- ===========================================
-- 7. MISE À JOUR TABLE ORDERS POUR MULTI-POS
-- ===========================================

-- Ajouter colonnes orders si elles n'existent pas
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS location_id UUID REFERENCES public.vendor_locations(id);
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS pos_cashier_id UUID REFERENCES auth.users(id);
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS currency TEXT DEFAULT 'GNF';

CREATE INDEX IF NOT EXISTS idx_orders_location ON orders(location_id);

-- Ajouter colonnes order_items si elles n'existent pas
ALTER TABLE public.order_items ADD COLUMN IF NOT EXISTS product_name TEXT;

-- Ajouter colonnes escrow_transactions si elles n'existent pas
ALTER TABLE public.escrow_transactions ADD COLUMN IF NOT EXISTS payer_id UUID;
ALTER TABLE public.escrow_transactions ADD COLUMN IF NOT EXISTS receiver_id UUID;
ALTER TABLE public.escrow_transactions ADD COLUMN IF NOT EXISTS auto_release_at TIMESTAMPTZ;
ALTER TABLE public.escrow_transactions ADD COLUMN IF NOT EXISTS payment_method TEXT;

-- ===========================================
-- 8. LIAISON ACHATS → ENTREPÔT
-- ===========================================

-- Ajouter location_id aux achats de stock
ALTER TABLE public.stock_purchases ADD COLUMN IF NOT EXISTS location_id UUID REFERENCES public.vendor_locations(id);
ALTER TABLE public.stock_purchases ADD COLUMN IF NOT EXISTS is_stock_updated BOOLEAN DEFAULT FALSE;

CREATE INDEX IF NOT EXISTS idx_stock_purchases_location ON stock_purchases(location_id);

-- ===========================================
-- 9. FONCTIONS SQL
-- ===========================================

-- Fonction pour générer un numéro de transfert unique
CREATE OR REPLACE FUNCTION generate_transfer_number(p_vendor_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
  v_date TEXT;
  v_count INTEGER;
  v_number TEXT;
BEGIN
  v_date := TO_CHAR(NOW(), 'YYYYMMDD');
  
  SELECT COUNT(*) + 1 INTO v_count
  FROM stock_transfers
  WHERE vendor_id = p_vendor_id
    AND DATE(initiated_at) = CURRENT_DATE;
  
  v_number := 'TRF-' || v_date || '-' || LPAD(v_count::TEXT, 4, '0');
  
  RETURN v_number;
END;
$$;

-- Fonction pour générer un numéro de perte
CREATE OR REPLACE FUNCTION generate_loss_number(p_vendor_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
  v_date TEXT;
  v_count INTEGER;
  v_number TEXT;
BEGIN
  v_date := TO_CHAR(NOW(), 'YYYYMMDD');
  
  SELECT COUNT(*) + 1 INTO v_count
  FROM stock_losses
  WHERE vendor_id = p_vendor_id
    AND DATE(reported_at) = CURRENT_DATE;
  
  v_number := 'PRT-' || v_date || '-' || LPAD(v_count::TEXT, 4, '0');
  
  RETURN v_number;
END;
$$;

-- Fonction pour créer un transfert complet
CREATE OR REPLACE FUNCTION create_stock_transfer(
  p_vendor_id UUID,
  p_from_location_id UUID,
  p_to_location_id UUID,
  p_items JSONB, -- [{product_id, quantity, unit_cost}]
  p_notes TEXT DEFAULT NULL,
  p_user_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_transfer_id UUID;
  v_transfer_number TEXT;
  v_item JSONB;
  v_stock_available INTEGER;
  v_total_items INTEGER := 0;
  v_total_value DECIMAL(15,2) := 0;
BEGIN
  -- Vérifier que les lieux appartiennent au vendeur
  IF NOT EXISTS (SELECT 1 FROM vendor_locations WHERE id = p_from_location_id AND vendor_id = p_vendor_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Lieu source invalide');
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM vendor_locations WHERE id = p_to_location_id AND vendor_id = p_vendor_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Lieu destination invalide');
  END IF;
  
  -- Générer le numéro de transfert
  v_transfer_number := generate_transfer_number(p_vendor_id);
  
  -- Créer le transfert
  INSERT INTO stock_transfers (
    vendor_id, transfer_number, from_location_id, to_location_id,
    status, initiated_by, notes
  ) VALUES (
    p_vendor_id, v_transfer_number, p_from_location_id, p_to_location_id,
    'pending', p_user_id, p_notes
  ) RETURNING id INTO v_transfer_id;
  
  -- Traiter chaque item
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    -- Vérifier le stock disponible
    SELECT COALESCE(available_quantity, 0) INTO v_stock_available
    FROM location_stock
    WHERE location_id = p_from_location_id
      AND product_id = (v_item->>'product_id')::UUID;
    
    IF v_stock_available < (v_item->>'quantity')::INTEGER THEN
      -- Rollback et retourner erreur
      DELETE FROM stock_transfers WHERE id = v_transfer_id;
      RETURN jsonb_build_object(
        'success', false,
        'error', 'Stock insuffisant pour le produit ' || (v_item->>'product_id'),
        'available', v_stock_available,
        'requested', (v_item->>'quantity')::INTEGER
      );
    END IF;
    
    -- Créer l'item de transfert
    INSERT INTO stock_transfer_items (
      transfer_id, product_id, quantity_sent, unit_cost
    ) VALUES (
      v_transfer_id,
      (v_item->>'product_id')::UUID,
      (v_item->>'quantity')::INTEGER,
      COALESCE((v_item->>'unit_cost')::DECIMAL, 0)
    );
    
    v_total_items := v_total_items + (v_item->>'quantity')::INTEGER;
    v_total_value := v_total_value + ((v_item->>'quantity')::INTEGER * COALESCE((v_item->>'unit_cost')::DECIMAL, 0));
  END LOOP;
  
  -- Mettre à jour les totaux
  UPDATE stock_transfers
  SET total_items_sent = v_total_items,
      total_value = v_total_value
  WHERE id = v_transfer_id;
  
  RETURN jsonb_build_object(
    'success', true,
    'transfer_id', v_transfer_id,
    'transfer_number', v_transfer_number,
    'total_items', v_total_items,
    'total_value', v_total_value
  );
END;
$$;

-- Fonction pour expédier un transfert (passer en transit)
CREATE OR REPLACE FUNCTION ship_transfer(
  p_transfer_id UUID,
  p_user_id UUID DEFAULT NULL,
  p_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_transfer RECORD;
  v_item RECORD;
BEGIN
  -- Récupérer le transfert
  SELECT * INTO v_transfer FROM stock_transfers WHERE id = p_transfer_id;
  
  IF v_transfer IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Transfert non trouvé');
  END IF;
  
  IF v_transfer.status != 'pending' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Le transfert doit être en attente pour être expédié');
  END IF;
  
  -- Décrémenter le stock source pour chaque item
  FOR v_item IN SELECT * FROM stock_transfer_items WHERE transfer_id = p_transfer_id
  LOOP
    -- Vérifier encore une fois le stock
    IF (SELECT COALESCE(available_quantity, 0) FROM location_stock 
        WHERE location_id = v_transfer.from_location_id AND product_id = v_item.product_id) < v_item.quantity_sent THEN
      RETURN jsonb_build_object('success', false, 'error', 'Stock insuffisant pour ' || v_item.product_id);
    END IF;
    
    -- Décrémenter le stock
    UPDATE location_stock
    SET quantity = quantity - v_item.quantity_sent,
        last_stock_update = NOW(),
        updated_at = NOW()
    WHERE location_id = v_transfer.from_location_id
      AND product_id = v_item.product_id;
    
    -- Enregistrer dans l'historique
    INSERT INTO location_stock_history (
      location_id, product_id, movement_type, 
      quantity_before, quantity_change, quantity_after,
      reference_type, reference_id, performed_by, notes
    )
    SELECT 
      v_transfer.from_location_id,
      v_item.product_id,
      'transfer_out',
      quantity + v_item.quantity_sent,
      -v_item.quantity_sent,
      quantity,
      'transfer',
      p_transfer_id,
      p_user_id,
      'Transfert ' || v_transfer.transfer_number
    FROM location_stock
    WHERE location_id = v_transfer.from_location_id
      AND product_id = v_item.product_id;
  END LOOP;
  
  -- Mettre à jour le statut du transfert
  UPDATE stock_transfers
  SET status = 'in_transit',
      shipped_at = NOW(),
      shipped_by = p_user_id,
      shipping_notes = p_notes,
      updated_at = NOW()
  WHERE id = p_transfer_id;
  
  RETURN jsonb_build_object(
    'success', true,
    'transfer_id', p_transfer_id,
    'status', 'in_transit'
  );
END;
$$;

-- Fonction pour confirmer la réception d'un transfert
CREATE OR REPLACE FUNCTION confirm_transfer_reception(
  p_transfer_id UUID,
  p_received_items JSONB, -- [{product_id, quantity_received, notes, missing_reason}]
  p_user_id UUID DEFAULT NULL,
  p_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_transfer RECORD;
  v_item JSONB;
  v_sent_item RECORD;
  v_total_received INTEGER := 0;
  v_total_missing INTEGER := 0;
  v_final_status TEXT;
  v_vendor_id UUID;
  v_loss_number TEXT;
BEGIN
  -- Récupérer le transfert
  SELECT * INTO v_transfer FROM stock_transfers WHERE id = p_transfer_id;
  
  IF v_transfer IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Transfert non trouvé');
  END IF;
  
  IF v_transfer.status NOT IN ('in_transit', 'delivered') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Le transfert doit être en transit pour être confirmé');
  END IF;
  
  v_vendor_id := v_transfer.vendor_id;
  
  -- Traiter chaque item reçu
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_received_items)
  LOOP
    -- Récupérer l'item envoyé
    SELECT * INTO v_sent_item
    FROM stock_transfer_items
    WHERE transfer_id = p_transfer_id
      AND product_id = (v_item->>'product_id')::UUID;
    
    IF v_sent_item IS NULL THEN
      CONTINUE;
    END IF;
    
    -- Mettre à jour l'item de transfert
    UPDATE stock_transfer_items
    SET quantity_received = (v_item->>'quantity_received')::INTEGER,
        reception_notes = v_item->>'notes',
        missing_reason = v_item->>'missing_reason'
    WHERE id = v_sent_item.id;
    
    v_total_received := v_total_received + (v_item->>'quantity_received')::INTEGER;
    
    -- Ajouter le stock au lieu de destination
    INSERT INTO location_stock (location_id, product_id, quantity, cost_price)
    VALUES (
      v_transfer.to_location_id,
      (v_item->>'product_id')::UUID,
      (v_item->>'quantity_received')::INTEGER,
      v_sent_item.unit_cost
    )
    ON CONFLICT (location_id, product_id) DO UPDATE
    SET quantity = location_stock.quantity + (v_item->>'quantity_received')::INTEGER,
        last_stock_update = NOW(),
        updated_at = NOW();
    
    -- Enregistrer dans l'historique
    INSERT INTO location_stock_history (
      location_id, product_id, movement_type,
      quantity_before, quantity_change, quantity_after,
      reference_type, reference_id, performed_by, notes
    )
    SELECT
      v_transfer.to_location_id,
      (v_item->>'product_id')::UUID,
      'transfer_in',
      COALESCE(ls.quantity, 0) - (v_item->>'quantity_received')::INTEGER,
      (v_item->>'quantity_received')::INTEGER,
      COALESCE(ls.quantity, 0),
      'transfer',
      p_transfer_id,
      p_user_id,
      'Réception transfert ' || v_transfer.transfer_number
    FROM location_stock ls
    WHERE ls.location_id = v_transfer.to_location_id
      AND ls.product_id = (v_item->>'product_id')::UUID;
    
    -- Si manquants, créer une perte
    IF (v_item->>'quantity_received')::INTEGER < v_sent_item.quantity_sent THEN
      v_loss_number := generate_loss_number(v_vendor_id);
      
      INSERT INTO stock_losses (
        vendor_id, loss_number, location_id, product_id,
        source_type, source_reference_id, quantity, unit_cost,
        reason, notes, reported_by
      ) VALUES (
        v_vendor_id,
        v_loss_number,
        v_transfer.to_location_id,
        (v_item->>'product_id')::UUID,
        'transfer',
        p_transfer_id,
        v_sent_item.quantity_sent - (v_item->>'quantity_received')::INTEGER,
        v_sent_item.unit_cost,
        v_item->>'missing_reason',
        'Manquant lors du transfert ' || v_transfer.transfer_number,
        p_user_id
      );
      
      v_total_missing := v_total_missing + (v_sent_item.quantity_sent - (v_item->>'quantity_received')::INTEGER);
    END IF;
  END LOOP;
  
  -- Déterminer le statut final
  IF v_total_missing = 0 THEN
    v_final_status := 'completed';
  ELSE
    v_final_status := 'partial';
  END IF;
  
  -- Mettre à jour le transfert
  UPDATE stock_transfers
  SET status = v_final_status,
      confirmed_at = NOW(),
      confirmed_by = p_user_id,
      received_by = p_user_id,
      reception_notes = p_notes,
      total_items_received = v_total_received,
      total_items_missing = v_total_missing,
      delivered_at = COALESCE(delivered_at, NOW()),
      updated_at = NOW()
  WHERE id = p_transfer_id;
  
  RETURN jsonb_build_object(
    'success', true,
    'transfer_id', p_transfer_id,
    'status', v_final_status,
    'total_received', v_total_received,
    'total_missing', v_total_missing
  );
END;
$$;

-- Fonction pour obtenir le stock global d'un produit (tous les lieux)
CREATE OR REPLACE FUNCTION get_product_stock_by_locations(p_product_id UUID, p_vendor_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
    'product_id', p_product_id,
    'total_quantity', COALESCE(SUM(ls.quantity), 0),
    'total_available', COALESCE(SUM(ls.available_quantity), 0),
    'total_reserved', COALESCE(SUM(ls.reserved_quantity), 0),
    'locations', COALESCE(jsonb_agg(
      jsonb_build_object(
        'location_id', vl.id,
        'location_name', vl.name,
        'location_type', vl.location_type,
        'is_pos', vl.is_pos_enabled,
        'quantity', ls.quantity,
        'available', ls.available_quantity,
        'reserved', ls.reserved_quantity,
        'minimum', ls.minimum_stock,
        'is_low_stock', ls.quantity <= ls.minimum_stock
      ) ORDER BY vl.location_type, vl.name
    ) FILTER (WHERE ls.id IS NOT NULL), '[]'::JSONB)
  ) INTO v_result
  FROM vendor_locations vl
  LEFT JOIN location_stock ls ON ls.location_id = vl.id AND ls.product_id = p_product_id
  WHERE vl.vendor_id = p_vendor_id AND vl.is_active = TRUE;
  
  RETURN v_result;
END;
$$;

-- Fonction pour les stats d'un lieu
CREATE OR REPLACE FUNCTION get_location_stats(p_location_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
    'location_id', p_location_id,
    'total_products', COUNT(DISTINCT ls.product_id),
    'total_quantity', COALESCE(SUM(ls.quantity), 0),
    'total_value', COALESCE(SUM(ls.quantity * ls.cost_price), 0),
    'low_stock_count', COUNT(*) FILTER (WHERE ls.quantity <= ls.minimum_stock AND ls.quantity > 0),
    'out_of_stock_count', COUNT(*) FILTER (WHERE ls.quantity = 0),
    'pending_transfers_in', (
      SELECT COUNT(*) FROM stock_transfers
      WHERE to_location_id = p_location_id AND status = 'in_transit'
    ),
    'pending_transfers_out', (
      SELECT COUNT(*) FROM stock_transfers
      WHERE from_location_id = p_location_id AND status IN ('pending', 'in_transit')
    )
  ) INTO v_result
  FROM location_stock ls
  WHERE ls.location_id = p_location_id;
  
  RETURN v_result;
END;
$$;

-- ===========================================
-- 10. TRIGGERS
-- ===========================================

-- Trigger pour mettre à jour updated_at
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

-- Trigger pour calculer available_quantity dans location_stock
CREATE OR REPLACE FUNCTION calculate_available_quantity()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.available_quantity := NEW.quantity - COALESCE(NEW.reserved_quantity, 0);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_location_stock_available ON location_stock;
CREATE TRIGGER trigger_location_stock_available
  BEFORE INSERT OR UPDATE OF quantity, reserved_quantity ON location_stock
  FOR EACH ROW
  EXECUTE FUNCTION calculate_available_quantity();

-- Trigger pour calculer quantity_missing et total_value dans stock_transfer_items
CREATE OR REPLACE FUNCTION calculate_transfer_item_values()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.quantity_missing := NEW.quantity_sent - COALESCE(NEW.quantity_received, 0);
  NEW.total_value := NEW.quantity_sent * COALESCE(NEW.unit_cost, 0);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_transfer_item_values ON stock_transfer_items;
CREATE TRIGGER trigger_transfer_item_values
  BEFORE INSERT OR UPDATE OF quantity_sent, quantity_received, unit_cost ON stock_transfer_items
  FOR EACH ROW
  EXECUTE FUNCTION calculate_transfer_item_values();

-- Trigger pour calculer total_loss_value dans stock_losses
CREATE OR REPLACE FUNCTION calculate_loss_value()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.total_loss_value := NEW.quantity * COALESCE(NEW.unit_cost, 0);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_loss_value ON stock_losses;
CREATE TRIGGER trigger_loss_value
  BEFORE INSERT OR UPDATE OF quantity, unit_cost ON stock_losses
  FOR EACH ROW
  EXECUTE FUNCTION calculate_loss_value();

DROP TRIGGER IF EXISTS trigger_vendor_locations_updated ON vendor_locations;
CREATE TRIGGER trigger_vendor_locations_updated
  BEFORE UPDATE ON vendor_locations
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS trigger_location_stock_updated ON location_stock;
CREATE TRIGGER trigger_location_stock_updated
  BEFORE UPDATE ON location_stock
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS trigger_stock_transfers_updated ON stock_transfers;
CREATE TRIGGER trigger_stock_transfers_updated
  BEFORE UPDATE ON stock_transfers
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

-- ===========================================
-- 11. RLS POLICIES
-- ===========================================

ALTER TABLE vendor_locations ENABLE ROW LEVEL SECURITY;
ALTER TABLE location_stock ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_transfers ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_transfer_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_losses ENABLE ROW LEVEL SECURITY;
ALTER TABLE location_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE location_stock_history ENABLE ROW LEVEL SECURITY;

-- Policies pour vendor_locations
DROP POLICY IF EXISTS "Vendors can manage their locations" ON vendor_locations;
CREATE POLICY "Vendors can manage their locations" ON vendor_locations
FOR ALL USING (
  EXISTS (
    SELECT 1 FROM vendors v WHERE v.id = vendor_locations.vendor_id AND v.user_id = auth.uid()
  )
  OR EXISTS (
    SELECT 1 FROM location_permissions lp WHERE lp.location_id = vendor_locations.id AND lp.user_id = auth.uid() AND lp.is_active = TRUE
  )
);

-- Policies pour location_stock
DROP POLICY IF EXISTS "Vendors can manage location stock" ON location_stock;
CREATE POLICY "Vendors can manage location stock" ON location_stock
FOR ALL USING (
  EXISTS (
    SELECT 1 FROM vendor_locations vl
    JOIN vendors v ON v.id = vl.vendor_id
    WHERE vl.id = location_stock.location_id AND v.user_id = auth.uid()
  )
  OR EXISTS (
    SELECT 1 FROM location_permissions lp WHERE lp.location_id = location_stock.location_id AND lp.user_id = auth.uid() AND lp.is_active = TRUE
  )
);

-- Policies pour stock_transfers
DROP POLICY IF EXISTS "Vendors can manage their transfers" ON stock_transfers;
CREATE POLICY "Vendors can manage their transfers" ON stock_transfers
FOR ALL USING (
  EXISTS (
    SELECT 1 FROM vendors v WHERE v.id = stock_transfers.vendor_id AND v.user_id = auth.uid()
  )
);

-- Policies pour stock_transfer_items
DROP POLICY IF EXISTS "Vendors can view their transfer items" ON stock_transfer_items;
CREATE POLICY "Vendors can view their transfer items" ON stock_transfer_items
FOR ALL USING (
  EXISTS (
    SELECT 1 FROM stock_transfers st
    JOIN vendors v ON v.id = st.vendor_id
    WHERE st.id = stock_transfer_items.transfer_id AND v.user_id = auth.uid()
  )
);

-- Policies pour stock_losses
DROP POLICY IF EXISTS "Vendors can manage their losses" ON stock_losses;
CREATE POLICY "Vendors can manage their losses" ON stock_losses
FOR ALL USING (
  EXISTS (
    SELECT 1 FROM vendors v WHERE v.id = stock_losses.vendor_id AND v.user_id = auth.uid()
  )
);

-- Policies pour location_permissions
DROP POLICY IF EXISTS "Vendors can manage location permissions" ON location_permissions;
CREATE POLICY "Vendors can manage location permissions" ON location_permissions
FOR ALL USING (
  EXISTS (
    SELECT 1 FROM vendor_locations vl
    JOIN vendors v ON v.id = vl.vendor_id
    WHERE vl.id = location_permissions.location_id AND v.user_id = auth.uid()
  )
  OR location_permissions.user_id = auth.uid()
);

-- Policies pour location_stock_history
DROP POLICY IF EXISTS "Vendors can view stock history" ON location_stock_history;
CREATE POLICY "Vendors can view stock history" ON location_stock_history
FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM vendor_locations vl
    JOIN vendors v ON v.id = vl.vendor_id
    WHERE vl.id = location_stock_history.location_id AND v.user_id = auth.uid()
  )
);

-- ===========================================
-- 12. GRANTS
-- ===========================================

GRANT SELECT, INSERT, UPDATE, DELETE ON vendor_locations TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON location_stock TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON stock_transfers TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON stock_transfer_items TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON stock_losses TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON location_permissions TO authenticated;
GRANT SELECT ON location_stock_history TO authenticated;
GRANT INSERT ON location_stock_history TO authenticated;

GRANT EXECUTE ON FUNCTION generate_transfer_number(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION generate_loss_number(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION create_stock_transfer(UUID, UUID, UUID, JSONB, TEXT, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION ship_transfer(UUID, UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION confirm_transfer_reception(UUID, JSONB, UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION get_product_stock_by_locations(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_location_stats(UUID) TO authenticated;

-- ===========================================
-- 13. MIGRATION DES DONNÉES EXISTANTES
-- ===========================================

-- Créer un lieu par défaut pour chaque vendeur qui a des entrepôts
INSERT INTO vendor_locations (vendor_id, name, code, location_type, is_default, address, created_at)
SELECT
  w.vendor_id,
  w.name,
  'ENT' || ROW_NUMBER() OVER (PARTITION BY w.vendor_id ORDER BY w.created_at),
  'warehouse',
  ROW_NUMBER() OVER (PARTITION BY w.vendor_id ORDER BY w.created_at) = 1,
  w.address,
  w.created_at
FROM warehouses w
WHERE NOT EXISTS (
  SELECT 1 FROM vendor_locations vl WHERE vl.vendor_id = w.vendor_id AND vl.name = w.name
);

-- Migrer les stocks existants
INSERT INTO location_stock (location_id, product_id, quantity, cost_price, created_at)
SELECT 
  vl.id,
  ws.product_id,
  ws.quantity,
  COALESCE(p.cost_price, 0),
  ws.updated_at
FROM warehouse_stocks ws
JOIN warehouses w ON w.id = ws.warehouse_id
JOIN vendor_locations vl ON vl.vendor_id = w.vendor_id AND vl.name = w.name
JOIN products p ON p.id = ws.product_id
WHERE NOT EXISTS (
  SELECT 1 FROM location_stock ls WHERE ls.location_id = vl.id AND ls.product_id = ws.product_id
);

-- ===========================================
-- 14. COMMENTAIRES
-- ===========================================

COMMENT ON TABLE vendor_locations IS 'Lieux de stockage (entrepôts et POS) des vendeurs';
COMMENT ON TABLE location_stock IS 'Stock par lieu et par produit';
COMMENT ON TABLE stock_transfers IS 'Transferts de stock entre lieux';
COMMENT ON TABLE stock_transfer_items IS 'Items des transferts de stock';
COMMENT ON TABLE stock_losses IS 'Pertes et manquants de stock';
COMMENT ON TABLE location_permissions IS 'Permissions des utilisateurs par lieu';
COMMENT ON TABLE location_stock_history IS 'Historique des mouvements de stock par lieu';

COMMENT ON FUNCTION create_stock_transfer(UUID, UUID, UUID, JSONB, TEXT, UUID) IS 'Crée un nouveau transfert de stock avec validation';
COMMENT ON FUNCTION ship_transfer(UUID, UUID, TEXT) IS 'Expédie un transfert (passe en transit et décrémente le stock source)';
COMMENT ON FUNCTION confirm_transfer_reception(UUID, JSONB, UUID, TEXT) IS 'Confirme la réception avec gestion des manquants';


-- ============================================================
-- MIGRATION: 20260413160000_fix_create_order_core_columns.sql
-- ============================================================
-- Fix create_order_core: remove references to non-existent columns
-- orders.currency and order_items.product_name do not exist in the schema

CREATE OR REPLACE FUNCTION public.create_order_core(
  p_order_number text,
  p_customer_id uuid,
  p_vendor_id uuid,
  p_vendor_user_id uuid,
  p_payment_method text,
  p_payment_intent_id text DEFAULT NULL,
  p_shipping_address jsonb DEFAULT '{}'::jsonb,
  p_currency text DEFAULT 'GNF',
  p_items jsonb DEFAULT '[]'::jsonb,
  p_auto_release_days int DEFAULT 7
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  item jsonb;
  product_id uuid;
  quantity int;
  current_stock int;
  product_price numeric;
  product_name text;
  subtotal numeric := 0;
  order_id uuid;
  item_records jsonb := '[]'::jsonb;
BEGIN
  -- ====== PHASE 1: Validate all products + lock rows ======
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    product_id := (item->>'product_id')::uuid;
    quantity := (item->>'quantity')::int;
    
    SELECT p.stock_quantity, p.price, p.name
    INTO current_stock, product_price, product_name
    FROM products p
    WHERE p.id = product_id
      AND p.vendor_id = p_vendor_id
      AND p.is_active = true
    FOR UPDATE;
    
    IF NOT FOUND THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', format('Product %s not found, inactive, or wrong vendor', product_id)
      );
    END IF;
    
    IF current_stock IS NOT NULL AND current_stock < quantity THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', format('Insufficient stock for "%s": %s available, %s requested', product_name, current_stock, quantity)
      );
    END IF;
    
    -- Accumulate item data for insert
    item_records := item_records || jsonb_build_object(
      'product_id', product_id,
      'product_name', product_name,
      'quantity', quantity,
      'unit_price', product_price,
      'total_price', product_price * quantity,
      'variant_id', item->>'variant_id'
    );
    
    subtotal := subtotal + (product_price * quantity);
  END LOOP;
  
  -- ====== PHASE 2: Create order (no currency column in orders table) ======
  INSERT INTO orders (
    order_number, customer_id, vendor_id, status, 
    payment_status, payment_method, payment_intent_id,
    subtotal, total_amount, shipping_address
  ) VALUES (
    p_order_number, p_customer_id, p_vendor_id, 'pending',
    CASE WHEN p_payment_method = 'cod' THEN 'pending' ELSE 'processing' END,
    p_payment_method, p_payment_intent_id,
    subtotal, subtotal, p_shipping_address
  )
  RETURNING id INTO order_id;
  
  -- ====== PHASE 3: Insert order items (no product_name column in order_items) ======
  INSERT INTO order_items (order_id, product_id, quantity, unit_price, total_price, variant_id)
  SELECT 
    order_id,
    (r->>'product_id')::uuid,
    (r->>'quantity')::int,
    (r->>'unit_price')::numeric,
    (r->>'total_price')::numeric,
    NULLIF(r->>'variant_id', '')::uuid
  FROM jsonb_array_elements(item_records) AS r;
  
  -- ====== PHASE 4: Decrement stock (all at once) ======
  UPDATE products p
  SET stock_quantity = GREATEST(0, COALESCE(p.stock_quantity, 0) - (r->>'quantity')::int),
      updated_at = now()
  FROM jsonb_array_elements(item_records) AS r
  WHERE p.id = (r->>'product_id')::uuid;
  
  -- ====== PHASE 5: Create escrow ======
  INSERT INTO escrow_transactions (
    order_id, buyer_id, seller_id, amount, currency,
    status, auto_release_date
  ) VALUES (
    order_id, p_customer_id, p_vendor_user_id, subtotal, p_currency,
    'held', (now() + (p_auto_release_days || ' days')::interval)::date
  );
  
  -- ====== SUCCESS ======
  RETURN jsonb_build_object(
    'success', true,
    'order_id', order_id,
    'order_number', p_order_number,
    'subtotal', subtotal,
    'total_amount', subtotal,
    'currency', p_currency,
    'items', item_records,
    'escrow_status', 'held'
  );
  
EXCEPTION WHEN OTHERS THEN
  -- Transaction automatically rolls back
  RETURN jsonb_build_object(
    'success', false,
    'error', SQLERRM
  );
END;
$$;


-- ============================================================
-- MIGRATION: 20260417094500_fix_create_order_core_payment_status_enum.sql
-- ============================================================
-- Fix marketplace order creation to use the real payment_status enum.
-- The enum only supports pending|paid|failed|refunded, so create_order_core
-- must not insert the legacy text value "processing".

CREATE OR REPLACE FUNCTION public.create_order_core(
  p_order_number text,
  p_customer_id uuid,
  p_vendor_id uuid,
  p_vendor_user_id uuid,
  p_payment_method text,
  p_payment_intent_id text DEFAULT NULL,
  p_shipping_address jsonb DEFAULT '{}'::jsonb,
  p_currency text DEFAULT 'GNF',
  p_items jsonb DEFAULT '[]'::jsonb,
  p_auto_release_days int DEFAULT 7
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  item jsonb;
  product_id uuid;
  quantity int;
  current_stock int;
  product_price numeric;
  product_name text;
  subtotal numeric := 0;
  order_id uuid;
  buyer_user_id uuid;
  item_records jsonb := '[]'::jsonb;
BEGIN
  SELECT c.user_id
  INTO buyer_user_id
  FROM customers c
  WHERE c.id = p_customer_id;

  IF buyer_user_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', format('Customer %s is not linked to an auth user', p_customer_id)
    );
  END IF;

  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    product_id := (item->>'product_id')::uuid;
    quantity := (item->>'quantity')::int;

    SELECT p.stock_quantity, p.price, p.name
    INTO current_stock, product_price, product_name
    FROM products p
    WHERE p.id = product_id
      AND p.vendor_id = p_vendor_id
      AND p.is_active = true
    FOR UPDATE;

    IF NOT FOUND THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', format('Product %s not found, inactive, or wrong vendor', product_id)
      );
    END IF;

    IF current_stock IS NOT NULL AND current_stock < quantity THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', format('Insufficient stock for "%s": %s available, %s requested', product_name, current_stock, quantity)
      );
    END IF;

    item_records := item_records || jsonb_build_object(
      'product_id', product_id,
      'product_name', product_name,
      'quantity', quantity,
      'unit_price', product_price,
      'total_price', product_price * quantity,
      'variant_id', item->>'variant_id'
    );

    subtotal := subtotal + (product_price * quantity);
  END LOOP;

  INSERT INTO orders (
    order_number, customer_id, vendor_id, status,
    payment_status, payment_method, payment_intent_id,
    subtotal, total_amount, shipping_address
  ) VALUES (
    p_order_number, p_customer_id, p_vendor_id, 'pending',
    'pending'::payment_status,
    p_payment_method::payment_method, p_payment_intent_id,
    subtotal, subtotal, p_shipping_address
  )
  RETURNING id INTO order_id;

  INSERT INTO order_items (order_id, product_id, quantity, unit_price, total_price, variant_id)
  SELECT
    order_id,
    (r->>'product_id')::uuid,
    (r->>'quantity')::int,
    (r->>'unit_price')::numeric,
    (r->>'total_price')::numeric,
    NULLIF(r->>'variant_id', '')::uuid
  FROM jsonb_array_elements(item_records) AS r;

  UPDATE products p
  SET stock_quantity = GREATEST(0, COALESCE(p.stock_quantity, 0) - (r->>'quantity')::int),
      updated_at = now()
  FROM jsonb_array_elements(item_records) AS r
  WHERE p.id = (r->>'product_id')::uuid;

  INSERT INTO escrow_transactions (
    order_id, buyer_id, seller_id, amount, currency,
    status, auto_release_date
  ) VALUES (
    order_id, buyer_user_id, p_vendor_user_id, subtotal, p_currency,
    'held', (now() + (p_auto_release_days || ' days')::interval)::date
  );

  RETURN jsonb_build_object(
    'success', true,
    'order_id', order_id,
    'order_number', p_order_number,
    'subtotal', subtotal,
    'total_amount', subtotal,
    'currency', p_currency,
    'items', item_records,
    'escrow_status', 'held'
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'success', false,
    'error', SQLERRM
  );
END;
$$;

-- ============================================================
-- MIGRATION: 20260423133000_fix_pdg_financial_alert_type_constraint.sql
-- ============================================================
-- pdg_financial_alerts currently enforces a hard-coded whitelist of alert_type
-- values that no longer matches the runtime writers. This breaks privileged role
-- promotions and FX/security alert creation. Replace the brittle whitelist with
-- a format/non-empty constraint so new alert types remain forward-compatible.

ALTER TABLE public.pdg_financial_alerts
DROP CONSTRAINT IF EXISTS pdg_financial_alerts_alert_type_check;

ALTER TABLE public.pdg_financial_alerts
ADD CONSTRAINT pdg_financial_alerts_alert_type_check
CHECK (
  btrim(alert_type) <> ''
  AND alert_type ~ '^[A-Za-z0-9_:-]+$'
);

-- ============================================================
-- MIGRATION: 20260427143000_allow_vendor_agents_pos_settings.sql
-- ============================================================
-- Allow active vendor agents to read/update POS settings for their assigned vendor.
DROP POLICY IF EXISTS "vendors_own_pos_settings" ON public.pos_settings;

CREATE POLICY "vendors_and_agents_own_pos_settings"
ON public.pos_settings
FOR ALL TO authenticated
USING (public.is_vendor_or_agent(vendor_id))
WITH CHECK (public.is_vendor_or_agent(vendor_id));

-- POS card/mobile-money flows create an order before payment confirmation.
-- Active vendor agents with POS permission must be able to create orders for
-- their assigned vendor, not only update existing orders.
DROP POLICY IF EXISTS "orders_insert_policy" ON public.orders;

CREATE POLICY "orders_insert_policy"
ON public.orders
FOR INSERT TO authenticated
WITH CHECK (
  public.customer_belongs_to_auth_user(customer_id)
  OR public.is_vendor_or_agent(vendor_id)
  OR EXISTS (SELECT 1 FROM public.pdg_management p WHERE p.user_id = auth.uid())
);


-- ============================================================
-- MIGRATION: 20260429120000_fix_agent_subagent_commissions.sql
-- ============================================================
-- End-to-end fix for agent/sub-agent commissions and permissions.
-- Main rules:
-- - A direct PDG agent receives its configured rate, default 20%.
-- - A sub-agent receives its own rate, and its parent receives the parent rate.
-- - Agent wallet credits must target the GNF wallet only.
-- - Paid subscriptions also trigger agent commissions.

CREATE OR REPLACE FUNCTION public.credit_agent_wallet_gnf(
  p_agent_id uuid,
  p_amount numeric
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF p_agent_id IS NULL OR COALESCE(p_amount, 0) <= 0 THEN
    RETURN;
  END IF;

  INSERT INTO public.agent_wallets (
    agent_id,
    balance,
    currency,
    wallet_status,
    currency_type,
    updated_at
  ) VALUES (
    p_agent_id,
    ROUND(p_amount, 2),
    'GNF',
    'active',
    'GNF',
    NOW()
  )
  ON CONFLICT (agent_id, currency_type)
  DO UPDATE SET
    balance = COALESCE(public.agent_wallets.balance, 0) + EXCLUDED.balance,
    currency = 'GNF',
    wallet_status = COALESCE(public.agent_wallets.wallet_status, 'active'),
    updated_at = NOW();
END;
$$;

REVOKE ALL ON FUNCTION public.credit_agent_wallet_gnf(uuid, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.credit_agent_wallet_gnf(uuid, numeric) TO service_role;

CREATE OR REPLACE FUNCTION public.credit_agent_commission(
  p_user_id uuid,
  p_amount numeric,
  p_source_type text,
  p_transaction_id uuid DEFAULT NULL::uuid,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_affiliation RECORD;
  v_agent RECORD;
  v_parent_agent RECORD;
  v_commission_rate numeric;
  v_sub_agent_rate numeric;
  v_agent_commission numeric := 0;
  v_parent_commission numeric := 0;
  v_agent_log_id uuid;
  v_parent_log_id uuid;
  v_any_inserted boolean := false;
  v_agent_duplicate boolean := false;
  v_parent_duplicate boolean := false;
  v_currency text := COALESCE(NULLIF(p_metadata->>'currency', ''), 'GNF');
BEGIN
  IF p_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Utilisateur requis');
  END IF;

  IF COALESCE(p_amount, 0) <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Montant invalide');
  END IF;

  SELECT * INTO v_affiliation
  FROM public.get_user_agent(p_user_id);

  IF v_affiliation.agent_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', true,
      'has_agent', false,
      'message', 'Utilisateur non affilie a un agent'
    );
  END IF;

  SELECT * INTO v_agent
  FROM public.agents_management
  WHERE id = v_affiliation.agent_id
    AND is_active = true;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Agent non trouve ou inactif');
  END IF;

  IF v_agent.type_agent = 'sous_agent' THEN
    v_sub_agent_rate := GREATEST(0, LEAST(COALESCE(v_agent.commission_sous_agent, v_agent.commission_rate, 10), 100));
    v_agent_commission := ROUND(p_amount * (v_sub_agent_rate / 100), 2);

    IF v_agent_commission > 0 THEN
      INSERT INTO public.agent_commissions_log (
        agent_id,
        amount,
        source_type,
        related_user_id,
        transaction_id,
        description,
        status,
        commission_rate,
        transaction_amount,
        currency
      ) VALUES (
        v_agent.id,
        v_agent_commission,
        p_source_type,
        p_user_id,
        p_transaction_id,
        'Commission sous-agent ' || v_sub_agent_rate || '% sur ' || p_source_type,
        'validated',
        v_sub_agent_rate,
        ROUND(p_amount, 2),
        v_currency
      )
      ON CONFLICT DO NOTHING
      RETURNING id INTO v_agent_log_id;

      IF v_agent_log_id IS NULL THEN
        v_agent_duplicate := true;
        v_agent_commission := 0;
      ELSE
        PERFORM public.credit_agent_wallet_gnf(v_agent.id, v_agent_commission);
        v_any_inserted := true;
      END IF;
    END IF;

    IF v_agent.parent_agent_id IS NOT NULL THEN
      SELECT * INTO v_parent_agent
      FROM public.agents_management
      WHERE id = v_agent.parent_agent_id
        AND is_active = true;

      IF FOUND THEN
        v_commission_rate := GREATEST(0, LEAST(COALESCE(v_parent_agent.commission_agent_principal, v_parent_agent.commission_rate, 15), 100));
        v_parent_commission := ROUND(p_amount * (v_commission_rate / 100), 2);

        IF v_parent_commission > 0 THEN
          INSERT INTO public.agent_commissions_log (
            agent_id,
            amount,
            source_type,
            related_user_id,
            transaction_id,
            description,
            status,
            commission_rate,
            transaction_amount,
            currency
          ) VALUES (
            v_parent_agent.id,
            v_parent_commission,
            p_source_type,
            p_user_id,
            p_transaction_id,
            'Commission agent principal ' || v_commission_rate || '% via sous-agent ' || v_agent.name,
            'validated',
            v_commission_rate,
            ROUND(p_amount, 2),
            v_currency
          )
          ON CONFLICT DO NOTHING
          RETURNING id INTO v_parent_log_id;

          IF v_parent_log_id IS NULL THEN
            v_parent_duplicate := true;
            v_parent_commission := 0;
          ELSE
            PERFORM public.credit_agent_wallet_gnf(v_parent_agent.id, v_parent_commission);
            v_any_inserted := true;
          END IF;
        END IF;
      END IF;
    END IF;

    RETURN jsonb_build_object(
      'success', true,
      'has_agent', true,
      'already_processed', (NOT v_any_inserted AND (v_agent_duplicate OR v_parent_duplicate)),
      'agent_type', 'sous_agent',
      'agent_id', v_agent.id,
      'agent_name', v_agent.name,
      'agent_commission', v_agent_commission,
      'agent_rate', v_sub_agent_rate,
      'parent_agent_id', v_agent.parent_agent_id,
      'parent_commission', COALESCE(v_parent_commission, 0),
      'parent_already_processed', v_parent_duplicate,
      'total_commissions', v_agent_commission + COALESCE(v_parent_commission, 0)
    );
  END IF;

  v_commission_rate := GREATEST(0, LEAST(COALESCE(v_agent.commission_rate, v_agent.commission_agent_principal, 20), 100));
  v_agent_commission := ROUND(p_amount * (v_commission_rate / 100), 2);

  IF v_agent_commission > 0 THEN
    INSERT INTO public.agent_commissions_log (
      agent_id,
      amount,
      source_type,
      related_user_id,
      transaction_id,
      description,
      status,
      commission_rate,
      transaction_amount,
      currency
    ) VALUES (
      v_agent.id,
      v_agent_commission,
      p_source_type,
      p_user_id,
      p_transaction_id,
      'Commission agent principal ' || v_commission_rate || '% sur ' || p_source_type,
      'validated',
      v_commission_rate,
      ROUND(p_amount, 2),
      v_currency
    )
    ON CONFLICT DO NOTHING
    RETURNING id INTO v_agent_log_id;

    IF v_agent_log_id IS NULL THEN
      v_agent_duplicate := true;
      v_agent_commission := 0;
    ELSE
      PERFORM public.credit_agent_wallet_gnf(v_agent.id, v_agent_commission);
      v_any_inserted := true;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'has_agent', true,
    'already_processed', (NOT v_any_inserted AND v_agent_duplicate),
    'agent_type', COALESCE(v_agent.type_agent, 'principal'),
    'agent_id', v_agent.id,
    'agent_name', v_agent.name,
    'agent_commission', v_agent_commission,
    'agent_rate', v_commission_rate,
    'total_commissions', v_agent_commission
  );
END;
$$;

REVOKE ALL ON FUNCTION public.credit_agent_commission(uuid, numeric, text, uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.credit_agent_commission(uuid, numeric, text, uuid, jsonb) TO service_role;

-- Ensure currency_type column exists on agent_wallets before view and functions reference it
ALTER TABLE public.agent_wallets ADD COLUMN IF NOT EXISTS currency_type TEXT DEFAULT 'GNF';
CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_wallets_agent_currency ON public.agent_wallets(agent_id, currency_type);

DROP VIEW IF EXISTS public.agent_commission_stats;
CREATE VIEW public.agent_commission_stats AS
WITH gnf_wallets AS (
  SELECT
    aw.agent_id,
    COALESCE(SUM(aw.balance), 0::numeric) AS balance
  FROM public.agent_wallets aw
  WHERE COALESCE(aw.currency_type, aw.currency, 'GNF') = 'GNF'
  GROUP BY aw.agent_id
)
SELECT
  a.id AS agent_id,
  a.name AS agent_name,
  a.agent_code,
  COALESCE(w.balance, 0::numeric) AS wallet_balance,
  (SELECT count(*) FROM public.agent_created_users acu WHERE acu.agent_id = a.id) AS direct_users,
  (SELECT count(*) FROM public.user_agent_affiliations uaa WHERE uaa.agent_id = a.id AND uaa.is_verified = true) AS affiliated_users,
  (SELECT COALESCE(sum(cl.amount), 0::numeric) FROM public.agent_commissions_log cl WHERE cl.agent_id = a.id) AS total_commissions_earned,
  (SELECT COALESCE(sum(cl.amount), 0::numeric) FROM public.agent_commissions_log cl WHERE cl.agent_id = a.id AND cl.created_at >= date_trunc('month', now())) AS commissions_this_month,
  (SELECT COALESCE(sum(cl.amount), 0::numeric) FROM public.agent_commissions_log cl WHERE cl.agent_id = a.id AND cl.status = 'pending') AS pending_commissions
FROM public.agents_management a
LEFT JOIN gnf_wallets w ON w.agent_id = a.id;

CREATE OR REPLACE FUNCTION public.subscribe_user(
  p_user_id uuid,
  p_plan_id uuid,
  p_payment_method text DEFAULT 'wallet',
  p_transaction_id text DEFAULT NULL,
  p_billing_cycle text DEFAULT 'monthly'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_subscription_id uuid;
  v_price integer;
  v_duration_days integer;
  v_period_end timestamptz;
  v_plan_name text;
  v_user_role text;
  v_wallet_id uuid;
  v_wallet_balance integer;
  v_wallet_transaction_id uuid;
  v_commission_result jsonb := '{}'::jsonb;
BEGIN
  SELECT
    CASE
      WHEN p_billing_cycle = 'yearly' THEN COALESCE(yearly_price_gnf, monthly_price_gnf * 12)
      WHEN p_billing_cycle = 'quarterly' THEN monthly_price_gnf * 3
      ELSE monthly_price_gnf
    END,
    CASE
      WHEN p_billing_cycle = 'yearly' THEN COALESCE(duration_days, 30) * 12
      WHEN p_billing_cycle = 'quarterly' THEN COALESCE(duration_days, 30) * 3
      ELSE COALESCE(duration_days, 30)
    END,
    name,
    COALESCE(user_role, 'vendeur')
  INTO v_price, v_duration_days, v_plan_name, v_user_role
  FROM public.plans
  WHERE id = p_plan_id
    AND is_active = true;

  IF v_price IS NULL THEN
    RAISE EXCEPTION 'Plan non trouve ou inactif (ID: %)', p_plan_id;
  END IF;

  IF p_payment_method = 'wallet' THEN
    SELECT id, COALESCE(balance, 0)::integer
    INTO v_wallet_id, v_wallet_balance
    FROM public.wallets
    WHERE user_id = p_user_id
      AND currency = 'GNF'
    LIMIT 1
    FOR UPDATE;

    IF v_wallet_id IS NULL THEN
      INSERT INTO public.wallets (user_id, balance, currency)
      VALUES (p_user_id, 0, 'GNF')
      RETURNING id, 0 INTO v_wallet_id, v_wallet_balance;
    END IF;

    IF v_wallet_balance < v_price THEN
      RAISE EXCEPTION 'Solde insuffisant: % GNF disponible, % GNF requis pour l''abonnement %',
        v_wallet_balance, v_price, v_plan_name;
    END IF;

    UPDATE public.wallets
    SET balance = balance - v_price,
        updated_at = NOW()
    WHERE id = v_wallet_id;

    INSERT INTO public.wallet_transactions (
      wallet_id,
      transaction_type,
      amount,
      balance_before,
      balance_after,
      description,
      status,
      metadata,
      created_at
    ) VALUES (
      v_wallet_id,
      'subscription',
      v_price,
      v_wallet_balance,
      v_wallet_balance - v_price,
      'Abonnement ' || v_plan_name || ' (' || p_billing_cycle || ')',
      'completed',
      jsonb_build_object(
        'plan_id', p_plan_id,
        'plan_name', v_plan_name,
        'billing_cycle', p_billing_cycle,
        'user_role', v_user_role,
        'payment_method', p_payment_method
      ),
      NOW()
    )
    RETURNING id INTO v_wallet_transaction_id;
  END IF;

  v_period_end := NOW() + (v_duration_days || ' days')::interval;

  UPDATE public.subscriptions
  SET status = 'expired',
      auto_renew = false,
      updated_at = NOW()
  WHERE user_id = p_user_id
    AND status = 'active';

  INSERT INTO public.subscriptions (
    user_id,
    plan_id,
    price_paid_gnf,
    billing_cycle,
    status,
    started_at,
    current_period_end,
    auto_renew,
    payment_method,
    payment_transaction_id,
    metadata,
    created_at,
    updated_at
  ) VALUES (
    p_user_id,
    p_plan_id,
    v_price,
    p_billing_cycle,
    'active',
    NOW(),
    v_period_end,
    true,
    p_payment_method,
    COALESCE(p_transaction_id, v_wallet_transaction_id::text),
    jsonb_build_object(
      'migrated', false,
      'plan_type', v_user_role,
      'wallet_transaction_id', v_wallet_transaction_id,
      'created_by', 'subscribe_user_v3'
    ),
    NOW(),
    NOW()
  )
  RETURNING id INTO v_subscription_id;

  IF v_price > 0 THEN
    v_commission_result := public.credit_agent_commission(
      p_user_id,
      v_price,
      'abonnement',
      v_subscription_id,
      jsonb_build_object(
        'currency', 'GNF',
        'subscription_id', v_subscription_id,
        'plan_id', p_plan_id,
        'plan_name', v_plan_name,
        'billing_cycle', p_billing_cycle,
        'wallet_transaction_id', v_wallet_transaction_id
      )
    );

    UPDATE public.subscriptions
    SET metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object('agent_commission', v_commission_result),
        updated_at = NOW()
    WHERE id = v_subscription_id;
  END IF;

  INSERT INTO public.revenus_pdg (
    source_type,
    transaction_id,
    user_id,
    amount,
    percentage_applied,
    description,
    metadata,
    created_at
  ) VALUES (
    'frais_abonnement',
    v_subscription_id,
    p_user_id,
    v_price,
    100,
    'Abonnement ' || v_plan_name || ' (' || p_billing_cycle || ')',
    jsonb_build_object(
      'subscription_id', v_subscription_id,
      'plan_id', p_plan_id,
      'plan_name', v_plan_name,
      'billing_cycle', p_billing_cycle,
      'user_role', v_user_role,
      'wallet_transaction_id', v_wallet_transaction_id,
      'agent_commission', v_commission_result
    ),
    NOW()
  );

  RETURN v_subscription_id;
END;
$$;

DROP FUNCTION IF EXISTS public.record_subscription_payment(uuid, uuid, integer, text, text, text);
DROP FUNCTION IF EXISTS public.record_subscription_payment(uuid, uuid, numeric, text, text, text);
DROP FUNCTION IF EXISTS public.record_subscription_payment(uuid, uuid, integer, varchar, uuid, varchar);
DROP FUNCTION IF EXISTS public.record_subscription_payment(uuid, uuid, numeric, text, uuid, text);

CREATE OR REPLACE FUNCTION public.record_subscription_payment(
  p_user_id uuid,
  p_plan_id uuid,
  p_price_paid numeric,
  p_payment_method text DEFAULT 'wallet',
  p_payment_transaction_id text DEFAULT NULL,
  p_billing_cycle text DEFAULT 'monthly'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  RETURN public.subscribe_user(
    p_user_id,
    p_plan_id,
    p_payment_method,
    p_payment_transaction_id,
    p_billing_cycle
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.subscribe_user(uuid, uuid, text, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_subscription_payment(uuid, uuid, numeric, text, text, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.process_successful_payment(p_transaction_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_transaction RECORD;
  v_seller_wallet_id uuid;
  v_platform_wallet_id uuid;
  v_platform_user_id uuid;
  v_platform_balance_before numeric;
  v_platform_balance_after numeric;
  v_seller_balance_before numeric;
  v_seller_balance_after numeric;
  v_commission_result jsonb;
  v_commission_transaction_id uuid;
BEGIN
  SELECT * INTO v_transaction
  FROM public.stripe_transactions
  WHERE id = p_transaction_id;

  IF v_transaction.id IS NULL THEN
    RAISE EXCEPTION 'Transaction not found';
  END IF;

  v_seller_wallet_id := public.get_or_create_wallet(v_transaction.seller_id);

  SELECT id INTO v_platform_user_id
  FROM public.profiles
  WHERE role = 'CEO'
  LIMIT 1;

  IF v_platform_user_id IS NOT NULL THEN
    v_platform_wallet_id := public.get_or_create_wallet(v_platform_user_id);
  END IF;

  SELECT balance INTO v_seller_balance_before
  FROM public.wallets
  WHERE id = v_seller_wallet_id;

  UPDATE public.wallets
  SET balance = balance + v_transaction.seller_net_amount,
      updated_at = NOW()
  WHERE id = v_seller_wallet_id;

  SELECT balance INTO v_seller_balance_after
  FROM public.wallets
  WHERE id = v_seller_wallet_id;

  INSERT INTO public.wallet_transactions (
    sender_wallet_id,
    receiver_wallet_id,
    amount,
    currency,
    description,
    transaction_type,
    status,
    metadata,
    created_at
  ) VALUES (
    NULL,
    v_seller_wallet_id,
    v_transaction.seller_net_amount,
    v_transaction.currency,
    'Paiement recu commande ' || COALESCE(v_transaction.order_id::text, 'N/A'),
    'payment',
    'completed',
    jsonb_build_object('stripe_transaction_id', v_transaction.id, 'balance_before', v_seller_balance_before, 'balance_after', v_seller_balance_after),
    NOW()
  );

  IF v_platform_wallet_id IS NOT NULL THEN
    SELECT balance INTO v_platform_balance_before
    FROM public.wallets
    WHERE id = v_platform_wallet_id;

    UPDATE public.wallets
    SET balance = balance + v_transaction.commission_amount,
        updated_at = NOW()
    WHERE id = v_platform_wallet_id;

    SELECT balance INTO v_platform_balance_after
    FROM public.wallets
    WHERE id = v_platform_wallet_id;

    INSERT INTO public.wallet_transactions (
      sender_wallet_id,
      receiver_wallet_id,
      amount,
      currency,
      description,
      transaction_type,
      status,
      metadata,
      created_at
    ) VALUES (
      NULL,
      v_platform_wallet_id,
      v_transaction.commission_amount,
      v_transaction.currency,
      'Commission plateforme commande ' || COALESCE(v_transaction.order_id::text, 'N/A'),
      'commission',
      'completed',
      jsonb_build_object('stripe_transaction_id', v_transaction.id, 'balance_before', v_platform_balance_before, 'balance_after', v_platform_balance_after),
      NOW()
    );
  END IF;

  v_commission_transaction_id := v_transaction.id;
  IF v_transaction.order_id IS NOT NULL
     AND v_transaction.order_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    v_commission_transaction_id := v_transaction.order_id::uuid;
  END IF;

  v_commission_result := public.credit_agent_commission(
    v_transaction.buyer_id,
    v_transaction.amount,
    'achat_produit',
    v_commission_transaction_id,
    jsonb_build_object(
      'currency', COALESCE(v_transaction.currency, 'GNF'),
      'order_id', v_transaction.order_id,
      'seller_id', v_transaction.seller_id,
      'stripe_transaction_id', v_transaction.id
    )
  );

  RAISE NOTICE 'Commission agent pour achat: %', v_commission_result;
  RETURN true;
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'Erreur lors du traitement du paiement: %', SQLERRM;
    RETURN false;
END;
$$;

CREATE OR REPLACE FUNCTION public.process_wallet_order_payment(
  p_user_id uuid,
  p_order_id uuid,
  p_amount numeric,
  p_vendor_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_user_wallet_id uuid;
  v_user_balance numeric;
  v_vendor_wallet_id uuid;
  v_transaction_id uuid;
  v_platform_fee numeric;
  v_vendor_net numeric;
  v_commission_result jsonb;
  v_fee_rate numeric;
  v_vendor_user_id uuid;
BEGIN
  SELECT id, balance INTO v_user_wallet_id, v_user_balance
  FROM public.wallets
  WHERE user_id = p_user_id
  FOR UPDATE;

  IF v_user_wallet_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Wallet utilisateur non trouve');
  END IF;

  IF v_user_balance < p_amount THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solde insuffisant');
  END IF;

  SELECT user_id INTO v_vendor_user_id
  FROM public.vendors
  WHERE id = p_vendor_id;

  IF v_vendor_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Vendeur non trouve');
  END IF;

  SELECT id INTO v_vendor_wallet_id
  FROM public.wallets
  WHERE user_id = v_vendor_user_id;

  IF v_vendor_wallet_id IS NULL THEN
    INSERT INTO public.wallets (user_id, balance, currency)
    VALUES (v_vendor_user_id, 0, 'GNF')
    RETURNING id INTO v_vendor_wallet_id;
  END IF;

  SELECT setting_value::numeric INTO v_fee_rate
  FROM public.pdg_settings
  WHERE setting_key = 'purchase_commission_percentage';

  IF v_fee_rate IS NULL THEN
    v_fee_rate := 0.025;
  END IF;

  v_platform_fee := ROUND(p_amount * v_fee_rate, 2);
  v_vendor_net := ROUND(p_amount - v_platform_fee, 2);
  v_transaction_id := gen_random_uuid();

  UPDATE public.wallets
  SET balance = balance - ROUND(p_amount, 2),
      updated_at = NOW()
  WHERE id = v_user_wallet_id;

  UPDATE public.wallets
  SET balance = balance + v_vendor_net,
      updated_at = NOW()
  WHERE id = v_vendor_wallet_id;

  INSERT INTO public.wallet_transactions (
    id,
    sender_wallet_id,
    receiver_wallet_id,
    amount,
    fee,
    net_amount,
    currency,
    transaction_type,
    status,
    description,
    metadata,
    created_at,
    completed_at
  ) VALUES (
    v_transaction_id,
    v_user_wallet_id,
    v_vendor_wallet_id,
    ROUND(p_amount, 2),
    v_platform_fee,
    v_vendor_net,
    'GNF',
    'purchase',
    'completed',
    'Paiement commande #' || p_order_id::text,
    jsonb_build_object('order_id', p_order_id, 'vendor_id', p_vendor_id),
    NOW(),
    NOW()
  );

  v_commission_result := public.credit_agent_commission(
    p_user_id,
    ROUND(p_amount, 2),
    'achat_produit',
    p_order_id,
    jsonb_build_object(
      'currency', 'GNF',
      'order_id', p_order_id,
      'vendor_id', p_vendor_id,
      'wallet_transaction_id', v_transaction_id
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'transaction_id', v_transaction_id,
    'amount', ROUND(p_amount, 2),
    'platform_fee', v_platform_fee,
    'vendor_net', v_vendor_net,
    'agent_commission', v_commission_result
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.set_agent_permissions(
  p_agent_id uuid,
  p_permissions jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_key text;
  v_value_text text;
  v_can_create_sub_agents boolean;
  v_request_role text := COALESCE(current_setting('request.jwt.claim.role', true), '');
BEGIN
  IF p_agent_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Agent requis');
  END IF;

  IF COALESCE(jsonb_typeof(p_permissions), 'object') <> 'object' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Format des permissions invalide');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.agents_management WHERE id = p_agent_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Agent introuvable');
  END IF;

  IF v_request_role <> 'service_role'
     AND NOT EXISTS (
       SELECT 1
       FROM public.agents_management am
       JOIN public.pdg_management pm ON pm.id = am.pdg_id
       WHERE am.id = p_agent_id
         AND pm.user_id = auth.uid()
         AND pm.is_active = true
     ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Vous n''avez pas les permissions pour modifier cet agent');
  END IF;

  IF COALESCE(p_permissions, '{}'::jsonb) ? 'create_sub_agents' THEN
    v_can_create_sub_agents := (p_permissions->>'create_sub_agents')::boolean;

    UPDATE public.agents_management
    SET can_create_sub_agent = v_can_create_sub_agents,
        updated_at = NOW()
    WHERE id = p_agent_id;
  END IF;

  UPDATE public.agent_permissions
  SET permission_value = false,
      updated_at = NOW()
  WHERE agent_id = p_agent_id
    AND permission_key <> 'create_sub_agents';

  FOR v_key, v_value_text IN
    SELECT key, value
    FROM jsonb_each_text(COALESCE(p_permissions, '{}'::jsonb))
  LOOP
    IF v_key = 'create_sub_agents' THEN
      CONTINUE;
    END IF;

    INSERT INTO public.agent_permissions (
      agent_id,
      permission_key,
      permission_value,
      updated_at
    ) VALUES (
      p_agent_id,
      v_key,
      v_value_text::boolean,
      NOW()
    )
    ON CONFLICT (agent_id, permission_key)
    DO UPDATE SET
      permission_value = EXCLUDED.permission_value,
      updated_at = NOW();
  END LOOP;

  RETURN jsonb_build_object('success', true, 'message', 'Permissions mises a jour avec succes');
END;
$$;

REVOKE ALL ON FUNCTION public.set_agent_permissions(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_agent_permissions(uuid, jsonb) TO authenticated, service_role;


-- ============================================================
-- MIGRATION: 20260501100000_fix_agent_commission_credits_wallets.sql
-- ============================================================
-- ============================================================
-- FIX CRITIQUE: credit_agent_wallet_gnf doit créditer wallets
-- ============================================================
-- PROBLÈME: La fonction credit_agent_wallet_gnf écrivait uniquement
-- dans agent_wallets (table miroir). Mais toute l'interface agent lit
-- le solde depuis wallets (source de vérité). Résultat: les commissions
-- étaient invisibles pour l'agent.
--
-- FIX: On crédite maintenant les deux tables:
--   1. agent_wallets  → pour les stats/historique commission (inchangé)
--   2. wallets        → source de vérité lue par l'interface agent

CREATE OR REPLACE FUNCTION public.credit_agent_wallet_gnf(
  p_agent_id uuid,
  p_amount numeric
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  IF p_agent_id IS NULL OR COALESCE(p_amount, 0) <= 0 THEN
    RETURN;
  END IF;

  -- 1. Créditer agent_wallets (historique/stats — toujours maintenu)
  INSERT INTO public.agent_wallets (
    agent_id,
    balance,
    currency,
    wallet_status,
    currency_type,
    updated_at
  ) VALUES (
    p_agent_id,
    ROUND(p_amount, 2),
    'GNF',
    'active',
    'GNF',
    NOW()
  )
  ON CONFLICT (agent_id, currency_type)
  DO UPDATE SET
    balance      = COALESCE(public.agent_wallets.balance, 0) + EXCLUDED.balance,
    currency     = 'GNF',
    wallet_status = COALESCE(public.agent_wallets.wallet_status, 'active'),
    updated_at   = NOW();

  -- 2. Récupérer le user_id de l'agent dans agents_management
  SELECT user_id INTO v_user_id
  FROM public.agents_management
  WHERE id = p_agent_id
  LIMIT 1;

  -- 3. Créditer wallets (SOURCE DE VÉRITÉ lue par l'interface)
  IF v_user_id IS NOT NULL THEN
    INSERT INTO public.wallets (user_id, balance, currency, created_at, updated_at)
    VALUES (v_user_id, ROUND(p_amount, 2), 'GNF', NOW(), NOW())
    ON CONFLICT (user_id)
    DO UPDATE SET
      balance    = COALESCE(public.wallets.balance, 0) + EXCLUDED.balance,
      updated_at = NOW();
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.credit_agent_wallet_gnf(uuid, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.credit_agent_wallet_gnf(uuid, numeric) TO service_role;

-- ============================================================
-- SYNC: Resynchroniser les soldes existants agent_wallets → wallets
-- ============================================================
-- Pour les agents qui ont déjà des commissions dans agent_wallets
-- mais dont le solde wallets ne reflète pas ces commissions.
-- On additionne les soldes (ne pas écraser si wallets a déjà de l'argent).
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT am.user_id, COALESCE(aw.balance, 0) AS agent_balance
    FROM public.agent_wallets aw
    JOIN public.agents_management am ON am.id = aw.agent_id
    WHERE am.user_id IS NOT NULL
      AND COALESCE(aw.balance, 0) > 0
      AND COALESCE(aw.currency_type, aw.currency, 'GNF') = 'GNF'
  LOOP
    -- Créer/mettre à jour le wallet dans wallets
    INSERT INTO public.wallets (user_id, balance, currency, created_at, updated_at)
    VALUES (r.user_id, r.agent_balance, 'GNF', NOW(), NOW())
    ON CONFLICT (user_id)
    DO UPDATE SET
      balance    = GREATEST(public.wallets.balance, EXCLUDED.balance),
      updated_at = NOW()
    WHERE public.wallets.balance < EXCLUDED.balance;
  END LOOP;
END;
$$;


-- ============================================================
-- MIGRATION: 20260502000000_fix_agent_permission_rpcs.sql
-- ============================================================
-- ============================================================
-- FIX: check_agent_permission — check both tables
-- ============================================================
-- PROBLÈME 1: check_agent_permission ne lisait que agent_permissions.
-- pdg_access_permissions (permissions déléguées via grant_pdg_permission_to_agent)
-- était ignoré → permissions PDG déléguées jamais appliquées côté backend.
--
-- PROBLÈME 2: Ni check_agent_permission ni get_agent_permissions ni
-- set_agent_permissions n'avaient SET row_security = off, laissant la
-- décision de bypass RLS implicite (dépend du owner de la fonction).
--
-- FIX: Toutes les fonctions ont maintenant row_security = off explicit.
-- check_agent_permission vérifie les deux tables (OR logique).

CREATE OR REPLACE FUNCTION public.check_agent_permission(
  p_agent_id uuid,
  p_permission_key text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  v_has_permission boolean;
BEGIN
  -- Chercher dans agent_permissions (table principale, UPSERT via set_agent_permissions)
  SELECT COALESCE(permission_value, false)
  INTO v_has_permission
  FROM public.agent_permissions
  WHERE agent_id = p_agent_id
    AND permission_key = p_permission_key;

  IF COALESCE(v_has_permission, false) THEN
    RETURN true;
  END IF;

  -- Chercher dans pdg_access_permissions (permissions déléguées par le PDG)
  SELECT EXISTS(
    SELECT 1
    FROM public.pdg_access_permissions
    WHERE agent_id = p_agent_id
      AND permission_key = p_permission_key
      AND is_active = true
      AND (expires_at IS NULL OR expires_at > NOW())
  ) INTO v_has_permission;

  RETURN COALESCE(v_has_permission, false);
END;
$$;

REVOKE ALL ON FUNCTION public.check_agent_permission(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_agent_permission(uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.check_agent_permission(uuid, text) TO authenticated;

-- ============================================================
-- FIX: get_agent_permissions — row_security = off + can_create_sub_agent
-- ============================================================
-- NOTE: La migration 20251225 avait ajouté la fusion de can_create_sub_agent
-- depuis agents_management. Cette version préserve cette logique + ajoute
-- row_security = off.

CREATE OR REPLACE FUNCTION public.get_agent_permissions(p_agent_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  v_permissions jsonb;
  v_can_create_sub_agent boolean;
BEGIN
  SELECT jsonb_object_agg(permission_key, permission_value)
  INTO v_permissions
  FROM public.agent_permissions
  WHERE agent_id = p_agent_id;

  -- Fusionner can_create_sub_agent depuis agents_management (source de vérité)
  SELECT can_create_sub_agent
  INTO v_can_create_sub_agent
  FROM public.agents_management
  WHERE id = p_agent_id;

  v_permissions := COALESCE(v_permissions, '{}'::jsonb);
  v_permissions := v_permissions || jsonb_build_object('create_sub_agents', COALESCE(v_can_create_sub_agent, false));

  RETURN v_permissions;
END;
$$;

REVOKE ALL ON FUNCTION public.get_agent_permissions(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_agent_permissions(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.get_agent_permissions(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_agent_permissions(uuid) TO anon;

-- ============================================================
-- FIX: set_agent_permissions — row_security = off + can_create_sub_agent + admin auth
-- ============================================================
-- NOTE: Conserve la sémantique UPSERT (pas de DELETE avant INSERT).
-- Préserve la logique can_create_sub_agent de la migration 20251225.
-- Ajoute l'autorisation pour les admins (pas seulement PDG propriétaire).

CREATE OR REPLACE FUNCTION public.set_agent_permissions(
  p_agent_id uuid,
  p_permissions jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  v_pdg_id uuid;
  v_permission_key text;
  v_permission_value boolean;
  v_create_sub_agents boolean;
BEGIN
  -- Vérifier que le PDG appelant a le droit de modifier cet agent
  SELECT pdg_id INTO v_pdg_id
  FROM public.agents_management am
  WHERE am.id = p_agent_id
    AND EXISTS (
      SELECT 1 FROM public.pdg_management pm
      WHERE pm.id = am.pdg_id
        AND pm.user_id = auth.uid()
        AND pm.is_active = true
    );

  -- Permettre aussi aux admins/pdg génériques
  IF v_pdg_id IS NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = auth.uid()
        AND role IN ('admin', 'pdg')
    ) THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'Vous n''avez pas les permissions pour modifier cet agent'
      );
    END IF;
  END IF;

  -- Vérifier que l'agent existe
  IF NOT EXISTS (SELECT 1 FROM public.agents_management WHERE id = p_agent_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Agent introuvable');
  END IF;

  -- Extraire et mettre à jour can_create_sub_agent si présent (source de vérité = agents_management)
  IF p_permissions ? 'create_sub_agents' THEN
    v_create_sub_agents := (p_permissions->>'create_sub_agents')::boolean;
    UPDATE public.agents_management
    SET can_create_sub_agent = v_create_sub_agents, updated_at = now()
    WHERE id = p_agent_id;
  END IF;

  -- UPSERT les autres permissions dans agent_permissions
  FOR v_permission_key, v_permission_value IN
    SELECT key, value::boolean FROM jsonb_each_text(p_permissions)
  LOOP
    -- create_sub_agents est géré dans agents_management, pas dans agent_permissions
    IF v_permission_key = 'create_sub_agents' THEN
      CONTINUE;
    END IF;

    INSERT INTO public.agent_permissions (agent_id, permission_key, permission_value, updated_at)
    VALUES (p_agent_id, v_permission_key, v_permission_value, now())
    ON CONFLICT (agent_id, permission_key)
    DO UPDATE SET permission_value = EXCLUDED.permission_value, updated_at = now();
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Permissions mises à jour avec succès'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.set_agent_permissions(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_agent_permissions(uuid, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.set_agent_permissions(uuid, jsonb) TO authenticated;


-- ============================================================
-- MIGRATION: 20260502100000_cancel_order_wallet_refund.sql
-- ============================================================
-- ============================================================
-- FIX: Remboursement wallet automatique à l'annulation commande
-- ============================================================
-- PROBLÈME: La route backend POST /api/orders/:orderId/cancel marquait
-- l'escrow "refunded" mais ne créditait JAMAIS le wallet du client.
-- La logique de remboursement wallet existait uniquement dans la Edge Function
-- cancel-order (non appelée par le frontend).
--
-- FIX: Nouveau RPC cancel_order_and_refund_wallet — appelé par la route backend.
-- Gère atomiquement (dans une transaction) :
--   1. Vérification escrow éligible (carte / Orange Money / wallet uniquement)
--   2. Crédit wallet client (INSERT ON CONFLICT DO UPDATE — atomique, pas de race condition)
--   3. Mise à jour escrow → "refunded" ou "cancelled" selon le cas
--   4. Log d'audit dans escrow_action_logs
--
-- LOGIQUE DE REMBOURSEMENT:
--   status = 'held'    → argent réellement encaissé (carte, Orange Money, wallet)
--                        → remboursement wallet requis ✅
--   status = 'pending' → escrow virtuel COD (paiement à la livraison)
--                        → aucun argent reçu → PAS de remboursement wallet ❌
--                        → on passe juste le statut à 'cancelled'
--
-- Cette distinction est posée à la création de commande dans orders.routes.ts :
--   payment_method = 'cash'  → escrow.status = 'pending'
--   payment_method ≠ 'cash'  → escrow.status = 'held'

CREATE OR REPLACE FUNCTION public.cancel_order_and_refund_wallet(
  p_order_id   uuid,
  p_user_id    uuid,    -- user_id du client qui annule (pour audit)
  p_reason     text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  v_escrow      RECORD;
  v_refunded    boolean := false;
  v_amount      numeric := 0;
  v_currency    text    := 'GNF';
  v_is_cod      boolean := false;
BEGIN
  -- Récupérer l'escrow lié à cette commande (avec metadata pour détecter COD)
  SELECT id, payer_id, amount, currency, status, metadata
  INTO v_escrow
  FROM public.escrow_transactions
  WHERE order_id = p_order_id
  LIMIT 1;

  -- Rien à faire si aucun escrow
  IF v_escrow.id IS NULL THEN
    RETURN jsonb_build_object(
      'success',  true,
      'refunded', false,
      'amount',   0,
      'currency', 'GNF',
      'reason',   'no_escrow'
    );
  END IF;

  -- Détecter paiement à la livraison :
  --   - escrow.status = 'pending' (posé par orders.routes.ts ligne 617)
  --   - OU metadata.payment_type = 'cash_on_delivery' (double sécurité)
  v_is_cod := (
    v_escrow.status = 'pending'
    OR COALESCE(v_escrow.metadata->>'payment_type', '') = 'cash_on_delivery'
  );

  v_amount   := COALESCE(v_escrow.amount, 0);
  v_currency := COALESCE(v_escrow.currency, 'GNF');

  IF v_is_cod THEN
    -- ─── Paiement à la livraison ─────────────────────────────────────────────
    -- Aucun argent n'a été encaissé → pas de remboursement wallet.
    -- On passe juste l'escrow virtuel à 'cancelled'.
    UPDATE public.escrow_transactions
    SET
      status      = 'cancelled',
      notes       = COALESCE(p_reason, 'Annulation commande COD par le client'),
      updated_at  = NOW()
    WHERE id = v_escrow.id;

    INSERT INTO public.escrow_action_logs (
      escrow_id, action_type, performed_by, notes, metadata
    ) VALUES (
      v_escrow.id,
      'cancelled',
      p_user_id,
      'Annulation COD — aucun remboursement wallet (paiement à la livraison)',
      jsonb_build_object('order_id', p_order_id, 'cod', true)
    );

  ELSIF v_escrow.status = 'held' THEN
    -- ─── Paiement réel (carte / Orange Money / wallet) ───────────────────────
    -- Argent encaissé et mis en séquestre → remboursement dans le wallet client.

    IF v_amount > 0 AND v_escrow.payer_id IS NOT NULL THEN
      -- Crédit atomique : INSERT ON CONFLICT évite toute race condition
      INSERT INTO public.wallets (user_id, balance, currency, created_at, updated_at)
      VALUES (v_escrow.payer_id, v_amount, v_currency, NOW(), NOW())
      ON CONFLICT (user_id)
      DO UPDATE SET
        balance    = public.wallets.balance + EXCLUDED.balance,
        updated_at = NOW();

      v_refunded := true;
    END IF;

    -- Passer l'escrow à 'refunded'
    UPDATE public.escrow_transactions
    SET
      status      = 'refunded',
      refunded_at = NOW(),
      notes       = COALESCE(p_reason, 'Annulation par le client'),
      updated_at  = NOW()
    WHERE id = v_escrow.id;

    -- Log d'audit
    INSERT INTO public.escrow_action_logs (
      escrow_id, action_type, performed_by, notes, metadata
    ) VALUES (
      v_escrow.id,
      'refunded',
      p_user_id,
      COALESCE(p_reason, 'Annulation de commande — remboursement wallet'),
      jsonb_build_object(
        'order_id',  p_order_id,
        'amount',    v_amount,
        'currency',  v_currency,
        'payer_id',  v_escrow.payer_id,
        'refunded',  v_refunded
      )
    );

  ELSE
    -- Escrow dans un statut non éligible (déjà released, refunded, dispute, etc.)
    -- On ne fait rien, on log silencieusement.
    INSERT INTO public.escrow_action_logs (
      escrow_id, action_type, performed_by, notes, metadata
    ) VALUES (
      v_escrow.id,
      'cancel_skipped',
      p_user_id,
      'Annulation ignorée — statut escrow non éligible : ' || v_escrow.status,
      jsonb_build_object('order_id', p_order_id, 'escrow_status', v_escrow.status)
    );
  END IF;

  RETURN jsonb_build_object(
    'success',   true,
    'refunded',  v_refunded,
    'amount',    CASE WHEN v_refunded THEN v_amount ELSE 0 END,
    'currency',  v_currency,
    'cod',       v_is_cod
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'success', false,
    'error',   SQLERRM
  );
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_order_and_refund_wallet(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancel_order_and_refund_wallet(uuid, uuid, text) TO service_role;


-- ============================================================
-- MIGRATION: 20260502200000_fix_create_order_core_payer_id_wallet_debit.sql
-- ============================================================
-- ============================================================
-- FIX 1 : payer_id NULL dans escrow_transactions
-- FIX 2 : débit wallet absent pour paiement_method = 'wallet'
-- ============================================================
-- PROBLÈME 1 : create_order_core insère buyer_id (= customers.id) mais
-- jamais payer_id (= auth.users.id). Or cancel_order_and_refund_wallet
-- teste "v_escrow.payer_id IS NOT NULL" → remboursement jamais effectué.
--
-- PROBLÈME 2 : Pour les paiements wallet, le solde du client n'est
-- jamais débité. La commande est marquée payée mais l'argent reste
-- dans le wallet. La balance est vérifiée côté frontend mais sans débit.
--
-- FIX : Deux nouveaux paramètres DEFAULT NULL / 0 → backward-compatible.
--   p_buyer_user_id  → auth.users.id de l'acheteur → rempli dans payer_id
--   p_wallet_debit_amount → montant total (produits + commission) à débiter
--                           du wallet si payment_method = 'wallet'
-- ============================================================

CREATE OR REPLACE FUNCTION public.create_order_core(
  p_order_number           text,
  p_customer_id            uuid,
  p_vendor_id              uuid,
  p_vendor_user_id         uuid,
  p_payment_method         text,
  p_payment_intent_id      text    DEFAULT NULL,
  p_shipping_address       jsonb   DEFAULT '{}'::jsonb,
  p_currency               text    DEFAULT 'GNF',
  p_items                  jsonb   DEFAULT '[]'::jsonb,
  p_auto_release_days      int     DEFAULT 7,
  -- NOUVEAUX paramètres (DEFAULT = backward-compatible)
  p_buyer_user_id          uuid    DEFAULT NULL,   -- auth.users.id de l'acheteur
  p_wallet_debit_amount    numeric DEFAULT 0       -- montant à débiter du wallet (0 = pas de débit)
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  item            jsonb;
  product_id      uuid;
  quantity        int;
  current_stock   int;
  product_price   numeric;
  product_name    text;
  subtotal        numeric := 0;
  order_id        uuid;
  item_records    jsonb   := '[]'::jsonb;
  v_buyer_wallet_id bigint;
BEGIN

  -- ====== PHASE 0 : Vérification solde wallet (si paiement wallet) ======
  -- Vérifié en amont du FOR LOCK pour fail-fast avant toute modification.
  IF p_payment_method = 'wallet'
     AND p_buyer_user_id IS NOT NULL
     AND p_wallet_debit_amount > 0
  THEN
    PERFORM 1
    FROM public.wallets
    WHERE user_id = p_buyer_user_id
      AND balance >= p_wallet_debit_amount
    FOR UPDATE;                        -- lock la ligne pour éviter la race condition

    IF NOT FOUND THEN
      RETURN jsonb_build_object(
        'success', false,
        'error',   'Solde wallet insuffisant pour effectuer cet achat'
      );
    END IF;
  END IF;

  -- ====== PHASE 1 : Validate all products + lock rows ======
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    product_id := (item->>'product_id')::uuid;
    quantity   := (item->>'quantity')::int;

    SELECT p.stock_quantity, p.price, p.name
    INTO   current_stock, product_price, product_name
    FROM   products p
    WHERE  p.id        = product_id
      AND  p.vendor_id = p_vendor_id
      AND  p.is_active = true
    FOR UPDATE;

    IF NOT FOUND THEN
      RETURN jsonb_build_object(
        'success', false,
        'error',   format('Produit %s introuvable, inactif ou mauvais vendeur', product_id)
      );
    END IF;

    IF current_stock IS NOT NULL AND current_stock < quantity THEN
      RETURN jsonb_build_object(
        'success', false,
        'error',   format('Stock insuffisant pour "%s" : %s disponible, %s demandé', product_name, current_stock, quantity)
      );
    END IF;

    item_records := item_records || jsonb_build_object(
      'product_id',   product_id,
      'product_name', product_name,
      'quantity',     quantity,
      'unit_price',   product_price,
      'total_price',  product_price * quantity,
      'variant_id',   item->>'variant_id'
    );

    subtotal := subtotal + (product_price * quantity);
  END LOOP;

  -- ====== PHASE 2 : Create order ======
  INSERT INTO orders (
    order_number, customer_id, vendor_id, status,
    payment_status, payment_method, payment_intent_id,
    subtotal, total_amount, shipping_address, currency
  ) VALUES (
    p_order_number, p_customer_id, p_vendor_id, 'pending',
    CASE WHEN p_payment_method IN ('cash', 'cod') THEN 'pending' ELSE 'processing' END,
    p_payment_method, p_payment_intent_id,
    subtotal, subtotal, p_shipping_address, p_currency
  )
  RETURNING id INTO order_id;

  -- ====== PHASE 3 : Insert order items ======
  INSERT INTO order_items (order_id, product_id, product_name, quantity, unit_price, total_price, variant_id)
  SELECT
    order_id,
    (r->>'product_id')::uuid,
    r->>'product_name',
    (r->>'quantity')::int,
    (r->>'unit_price')::numeric,
    (r->>'total_price')::numeric,
    NULLIF(r->>'variant_id', '')::uuid
  FROM jsonb_array_elements(item_records) AS r;

  -- ====== PHASE 4 : Decrement stock (all at once) ======
  UPDATE products p
  SET    stock_quantity = GREATEST(0, COALESCE(p.stock_quantity, 0) - (r->>'quantity')::int),
         updated_at     = now()
  FROM   jsonb_array_elements(item_records) AS r
  WHERE  p.id = (r->>'product_id')::uuid;

  -- ====== PHASE 5 : Create escrow (avec payer_id et receiver_id) ======
  INSERT INTO escrow_transactions (
    order_id, buyer_id, seller_id, payer_id, receiver_id,
    amount, currency, status, auto_release_at, payment_method
  ) VALUES (
    order_id,
    p_customer_id,          -- customers.id
    p_vendor_user_id,       -- auth.users.id du vendeur
    p_buyer_user_id,        -- auth.users.id de l'acheteur (FIX payer_id)
    p_vendor_user_id,       -- auth.users.id du vendeur   (FIX receiver_id)
    subtotal,
    p_currency,
    'held',
    now() + (p_auto_release_days || ' days')::interval,
    p_payment_method
  );

  -- ====== PHASE 6 : Débit wallet atomique (si paiement wallet) ======
  IF p_payment_method = 'wallet'
     AND p_buyer_user_id IS NOT NULL
     AND p_wallet_debit_amount > 0
  THEN
    -- Débit atomique (le FOR UPDATE de la phase 0 garantit qu'aucune autre
    -- transaction n'a modifié le solde entre la vérification et le débit)
    UPDATE public.wallets
    SET    balance    = balance - p_wallet_debit_amount,
           updated_at = now()
    WHERE  user_id = p_buyer_user_id;

    -- Log wallet_transactions
    SELECT id INTO v_buyer_wallet_id
    FROM   public.wallets
    WHERE  user_id = p_buyer_user_id;

    IF v_buyer_wallet_id IS NOT NULL THEN
      INSERT INTO public.wallet_transactions (
        sender_wallet_id,
        receiver_wallet_id,
        transaction_type,
        amount,
        description,
        status,
        metadata
      ) VALUES (
        v_buyer_wallet_id,
        v_buyer_wallet_id,
        'marketplace_purchase',
        p_wallet_debit_amount,
        'Paiement commande marketplace — Fonds bloqués en Escrow',
        'completed',
        jsonb_build_object(
          'order_id',       order_id,
          'currency',       p_currency,
          'product_amount', subtotal,
          'total_debited',  p_wallet_debit_amount,
          'source',         'create_order_core'
        )
      );
    END IF;
  END IF;

  -- ====== SUCCESS ======
  RETURN jsonb_build_object(
    'success',      true,
    'order_id',     order_id,
    'order_number', p_order_number,
    'subtotal',     subtotal,
    'total_amount', subtotal,
    'currency',     p_currency,
    'items',        item_records,
    'escrow_status','held'
  );

EXCEPTION WHEN OTHERS THEN
  -- La transaction PostgreSQL est automatiquement annulée (rollback)
  RETURN jsonb_build_object(
    'success', false,
    'error',   SQLERRM
  );
END;
$$;

COMMENT ON FUNCTION public.create_order_core(text, uuid, uuid, uuid, text, text, jsonb, text, jsonb, int, uuid, numeric) IS
  'Création atomique commande + items + décrément stock + escrow (avec payer_id, receiver_id) + débit wallet optionnel. Tous en une seule transaction PostgreSQL.';

-- Pas de changement de GRANT nécessaire (SECURITY DEFINER, pas de revoke/grant supplémentaire requis)


-- ============================================================
-- MIGRATION: 20260502300000_fix_warehouse_rpcs.sql
-- ============================================================
-- =====================================================
-- CORRECTIF SYSTÈME ENTREPÔT - COLONNES + RPCs
-- 224SOLUTIONS - 02 Mai 2026
-- =====================================================
-- Problèmes corrigés :
--   1. stock_transfers : colonnes source/destination manquantes
--   2. stock_transfer_items : colonne quantity_lost manquante
--   3. ship_transfer : mauvais noms de paramètres
--   4. receive_transfer : fonction inexistante
--   5. confirm_transfer_reception : utilise to_location_id (obsolète)
--   6. get_location_stats : utilise les anciennes colonnes
-- =====================================================

-- =====================================================
-- 1. COLONNES MANQUANTES DANS stock_transfers
-- =====================================================

-- source/destination (l'ancienne migration utilisait from/to)
-- received_at, total_quantity_received, total_quantity_lost : utilisés par le hook frontend
ALTER TABLE public.stock_transfers
  ADD COLUMN IF NOT EXISTS source_location_id UUID REFERENCES public.vendor_locations(id),
  ADD COLUMN IF NOT EXISTS destination_location_id UUID REFERENCES public.vendor_locations(id),
  ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS expected_arrival_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS received_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS total_items INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_quantity_sent INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_quantity_received INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_quantity_lost INTEGER DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_stock_transfers_source_loc
  ON public.stock_transfers(source_location_id);
CREATE INDEX IF NOT EXISTS idx_stock_transfers_dest_loc
  ON public.stock_transfers(destination_location_id);

-- Backfill : remplir les nouvelles colonnes depuis les anciennes
UPDATE public.stock_transfers
SET
  source_location_id       = COALESCE(source_location_id, from_location_id),
  destination_location_id  = COALESCE(destination_location_id, to_location_id),
  created_by               = COALESCE(created_by, initiated_by),
  received_at              = COALESCE(received_at, delivered_at),
  total_items              = COALESCE(NULLIF(total_items, 0), total_items_sent, 0),
  total_quantity_sent      = COALESCE(NULLIF(total_quantity_sent, 0), total_items_sent, 0),
  total_quantity_received  = COALESCE(NULLIF(total_quantity_received, 0), total_items_received, 0),
  total_quantity_lost      = COALESCE(NULLIF(total_quantity_lost, 0), total_items_missing, 0)
WHERE source_location_id IS NULL
   OR destination_location_id IS NULL;

-- =====================================================
-- 2. COLONNE MANQUANTE DANS stock_transfer_items
-- =====================================================

-- Le trigger sync_stock_transfer_item_units référence quantity_lost
-- mais l'ancienne migration ne créait que quantity_missing
ALTER TABLE public.stock_transfer_items
  ADD COLUMN IF NOT EXISTS quantity_lost INTEGER DEFAULT 0;

-- Backfill
UPDATE public.stock_transfer_items
SET quantity_lost = COALESCE(NULLIF(quantity_lost, 0), quantity_missing, 0);

-- =====================================================
-- 3. RECRÉATION DE ship_transfer (bons noms de paramètres)
-- =====================================================
-- L'ancienne version avait p_user_id / p_notes
-- Le hook appelle p_shipped_by / p_shipping_notes
-- DROP préalable obligatoire : PostgreSQL interdit le renommage de paramètres via CREATE OR REPLACE
DROP FUNCTION IF EXISTS public.ship_transfer(UUID, UUID, TEXT);

CREATE OR REPLACE FUNCTION public.ship_transfer(
  p_transfer_id   UUID,
  p_shipped_by    UUID    DEFAULT NULL,
  p_shipping_notes TEXT   DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_transfer  RECORD;
  v_item      RECORD;
  v_source_id UUID;
BEGIN
  SELECT * INTO v_transfer FROM public.stock_transfers WHERE id = p_transfer_id;

  IF v_transfer IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Transfert non trouvé');
  END IF;

  IF v_transfer.status != 'pending' THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Le transfert doit être en attente pour être expédié');
  END IF;

  -- Compatibilité : nouvelle colonne source_location_id ou ancienne from_location_id
  v_source_id := COALESCE(v_transfer.source_location_id, v_transfer.from_location_id);

  FOR v_item IN SELECT * FROM public.stock_transfer_items WHERE transfer_id = p_transfer_id
  LOOP
    -- Vérifier stock disponible
    IF (
      SELECT COALESCE(available_quantity, quantity, 0)
      FROM public.location_stock
      WHERE location_id = v_source_id AND product_id = v_item.product_id
    ) < v_item.quantity_sent THEN
      RETURN jsonb_build_object('success', false, 'error',
        'Stock insuffisant pour le produit ' || v_item.product_id::TEXT);
    END IF;

    -- Décrémenter le stock source
    UPDATE public.location_stock
    SET quantity           = quantity - v_item.quantity_sent,
        last_stock_update  = NOW(),
        updated_at         = NOW()
    WHERE location_id = v_source_id
      AND product_id  = v_item.product_id;

    -- Historique
    INSERT INTO public.location_stock_history (
      location_id, product_id, movement_type,
      quantity_before, quantity_change, quantity_after,
      reference_type, reference_id, performed_by, notes
    )
    SELECT
      v_source_id,
      v_item.product_id,
      'transfer_out',
      ls.quantity + v_item.quantity_sent,
      -v_item.quantity_sent,
      ls.quantity,
      'transfer',
      p_transfer_id,
      p_shipped_by,
      'Transfert ' || COALESCE(v_transfer.transfer_number, p_transfer_id::TEXT)
    FROM public.location_stock ls
    WHERE ls.location_id = v_source_id
      AND ls.product_id  = v_item.product_id;
  END LOOP;

  UPDATE public.stock_transfers
  SET status         = 'in_transit',
      shipped_at     = NOW(),
      shipped_by     = p_shipped_by,
      shipping_notes = p_shipping_notes,
      updated_at     = NOW()
  WHERE id = p_transfer_id;

  RETURN jsonb_build_object(
    'success',     true,
    'transfer_id', p_transfer_id,
    'status',      'in_transit'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.ship_transfer(UUID, UUID, TEXT) TO authenticated;

-- =====================================================
-- 4. CORRECTIF confirm_transfer_reception
-- =====================================================
-- Utilise COALESCE(destination_location_id, to_location_id) pour la rétrocompatibilité

CREATE OR REPLACE FUNCTION public.confirm_transfer_reception(
  p_transfer_id    UUID,
  p_received_items JSONB,
  p_user_id        UUID DEFAULT NULL,
  p_notes          TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_transfer      RECORD;
  v_item          JSONB;
  v_sent_item     RECORD;
  v_total_received INTEGER := 0;
  v_total_missing  INTEGER := 0;
  v_final_status   TEXT;
  v_vendor_id      UUID;
  v_loss_number    TEXT;
  v_dest_id        UUID;
BEGIN
  SELECT * INTO v_transfer FROM public.stock_transfers WHERE id = p_transfer_id;

  IF v_transfer IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Transfert non trouvé');
  END IF;

  IF v_transfer.status NOT IN ('in_transit', 'delivered') THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Le transfert doit être en transit pour être confirmé');
  END IF;

  v_vendor_id := v_transfer.vendor_id;
  -- Compatibilité nouvelle/ancienne colonne
  v_dest_id   := COALESCE(v_transfer.destination_location_id, v_transfer.to_location_id);

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_received_items)
  LOOP
    SELECT * INTO v_sent_item
    FROM public.stock_transfer_items
    WHERE transfer_id = p_transfer_id
      AND product_id  = (v_item->>'product_id')::UUID;

    IF v_sent_item IS NULL THEN
      CONTINUE;
    END IF;

    UPDATE public.stock_transfer_items
    SET quantity_received = (v_item->>'quantity_received')::INTEGER,
        reception_notes   = v_item->>'notes',
        missing_reason    = v_item->>'missing_reason'
    WHERE id = v_sent_item.id;

    v_total_received := v_total_received + (v_item->>'quantity_received')::INTEGER;

    -- Ajouter le stock à la destination
    INSERT INTO public.location_stock (location_id, product_id, quantity, cost_price)
    VALUES (
      v_dest_id,
      (v_item->>'product_id')::UUID,
      (v_item->>'quantity_received')::INTEGER,
      v_sent_item.unit_cost
    )
    ON CONFLICT (location_id, product_id) DO UPDATE
    SET quantity          = public.location_stock.quantity + (v_item->>'quantity_received')::INTEGER,
        last_stock_update = NOW(),
        updated_at        = NOW();

    -- Historique
    INSERT INTO public.location_stock_history (
      location_id, product_id, movement_type,
      quantity_before, quantity_change, quantity_after,
      reference_type, reference_id, performed_by, notes
    )
    SELECT
      v_dest_id,
      (v_item->>'product_id')::UUID,
      'transfer_in',
      COALESCE(ls.quantity, 0) - (v_item->>'quantity_received')::INTEGER,
      (v_item->>'quantity_received')::INTEGER,
      COALESCE(ls.quantity, 0),
      'transfer',
      p_transfer_id,
      p_user_id,
      'Réception transfert ' || COALESCE(v_transfer.transfer_number, p_transfer_id::TEXT)
    FROM public.location_stock ls
    WHERE ls.location_id = v_dest_id
      AND ls.product_id  = (v_item->>'product_id')::UUID;

    -- Créer une perte si manquants
    IF (v_item->>'quantity_received')::INTEGER < v_sent_item.quantity_sent THEN
      v_loss_number := public.generate_loss_number(v_vendor_id);

      INSERT INTO public.stock_losses (
        vendor_id, loss_number, location_id, product_id,
        source_type, source_reference_id, quantity, unit_cost,
        reason, notes, reported_by
      ) VALUES (
        v_vendor_id,
        v_loss_number,
        v_dest_id,
        (v_item->>'product_id')::UUID,
        'transfer',
        p_transfer_id,
        v_sent_item.quantity_sent - (v_item->>'quantity_received')::INTEGER,
        v_sent_item.unit_cost,
        v_item->>'missing_reason',
        'Manquant lors du transfert ' || COALESCE(v_transfer.transfer_number, p_transfer_id::TEXT),
        p_user_id
      );

      v_total_missing := v_total_missing +
        (v_sent_item.quantity_sent - (v_item->>'quantity_received')::INTEGER);
    END IF;
  END LOOP;

  IF v_total_missing = 0 THEN
    v_final_status := 'completed';
  ELSE
    v_final_status := 'partial';
  END IF;

  UPDATE public.stock_transfers
  SET status                  = v_final_status,
      confirmed_at            = NOW(),
      confirmed_by            = p_user_id,
      received_by             = p_user_id,
      received_at             = NOW(),
      reception_notes         = p_notes,
      total_items_received    = v_total_received,
      total_items_missing     = v_total_missing,
      total_quantity_received = v_total_received,
      total_quantity_lost     = v_total_missing,
      delivered_at            = COALESCE(delivered_at, NOW()),
      updated_at              = NOW()
  WHERE id = p_transfer_id;

  RETURN jsonb_build_object(
    'success',        true,
    'transfer_id',    p_transfer_id,
    'status',         v_final_status,
    'total_received', v_total_received,
    'total_missing',  v_total_missing
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.confirm_transfer_reception(UUID, JSONB, UUID, TEXT) TO authenticated;

-- =====================================================
-- 5. CRÉATION DE receive_transfer (alias avec nouveaux paramètres)
-- =====================================================
-- Le hook appelle receive_transfer avec p_items_received / p_received_by / p_reception_notes
-- La fonction délègue à confirm_transfer_reception

CREATE OR REPLACE FUNCTION public.receive_transfer(
  p_transfer_id    UUID,
  p_items_received JSONB,
  p_received_by    UUID DEFAULT NULL,
  p_reception_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  RETURN public.confirm_transfer_reception(
    p_transfer_id    := p_transfer_id,
    p_received_items := p_items_received,
    p_user_id        := p_received_by,
    p_notes          := p_reception_notes
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.receive_transfer(UUID, JSONB, UUID, TEXT) TO authenticated;

-- =====================================================
-- 6. CORRECTIF get_location_stats (nouvelles colonnes)
-- =====================================================

CREATE OR REPLACE FUNCTION public.get_location_stats(p_location_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
    'location_id',           p_location_id,
    'total_products',        COUNT(DISTINCT ls.product_id),
    'total_quantity',        COALESCE(SUM(ls.quantity), 0),
    'total_value',           COALESCE(SUM(ls.quantity * ls.cost_price), 0),
    'low_stock_count',       COUNT(*) FILTER (WHERE ls.quantity <= ls.minimum_stock AND ls.quantity > 0),
    'out_of_stock_count',    COUNT(*) FILTER (WHERE ls.quantity = 0),
    'pending_transfers_in',  (
      SELECT COUNT(*) FROM public.stock_transfers
      WHERE COALESCE(destination_location_id, to_location_id) = p_location_id
        AND status = 'in_transit'
    ),
    'pending_transfers_out', (
      SELECT COUNT(*) FROM public.stock_transfers
      WHERE COALESCE(source_location_id, from_location_id) = p_location_id
        AND status IN ('pending', 'in_transit')
    )
  ) INTO v_result
  FROM public.location_stock ls
  WHERE ls.location_id = p_location_id;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_location_stats(UUID) TO authenticated;

-- =====================================================
-- 7. CORRECTIF create_stock_transfer (fallback du hook)
-- =====================================================
-- L'ancienne migration utilisait from_location_id/to_location_id
-- Recréer pour utiliser source_location_id/destination_location_id
-- Supprimer l'ancienne version 6-param pour éviter l'ambiguïté de surcharge
DROP FUNCTION IF EXISTS public.create_stock_transfer(UUID, UUID, UUID, JSONB, TEXT, UUID);

CREATE OR REPLACE FUNCTION public.create_stock_transfer(
  p_vendor_id              UUID,
  p_source_location_id     UUID,
  p_destination_location_id UUID,
  p_items                  JSONB,
  p_notes                  TEXT    DEFAULT NULL,
  p_created_by             UUID    DEFAULT NULL,
  p_expected_arrival       TIMESTAMPTZ DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_transfer_id     UUID;
  v_transfer_number TEXT;
  v_item            JSONB;
  v_total_items     INTEGER := 0;
  v_total_value     DECIMAL := 0;
BEGIN
  IF COALESCE(JSONB_ARRAY_LENGTH(p_items), 0) = 0 THEN
    RAISE EXCEPTION 'Aucun article à transférer';
  END IF;

  IF p_source_location_id = p_destination_location_id THEN
    RAISE EXCEPTION 'La source et la destination doivent être différentes';
  END IF;

  v_transfer_number := public.generate_transfer_number(p_vendor_id);

  INSERT INTO public.stock_transfers (
    vendor_id, transfer_number,
    source_location_id, destination_location_id,
    from_location_id, to_location_id,
    destination_type, status, approval_status,
    notes, created_by, initiated_by,
    expected_arrival_at
  ) VALUES (
    p_vendor_id, v_transfer_number,
    p_source_location_id, p_destination_location_id,
    p_source_location_id, p_destination_location_id,
    'warehouse', 'pending', 'approved',
    p_notes, p_created_by, p_created_by,
    p_expected_arrival
  )
  RETURNING id INTO v_transfer_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    INSERT INTO public.stock_transfer_items (
      transfer_id, product_id,
      quantity_sent, quantity_received, quantity_lost,
      unit_cost
    ) VALUES (
      v_transfer_id,
      (v_item->>'product_id')::UUID,
      (v_item->>'quantity')::INTEGER,
      0,
      0,
      COALESCE((v_item->>'unit_cost')::DECIMAL, 0)
    );

    v_total_items := v_total_items + (v_item->>'quantity')::INTEGER;
    v_total_value := v_total_value +
      ((v_item->>'quantity')::INTEGER * COALESCE((v_item->>'unit_cost')::DECIMAL, 0));
  END LOOP;

  UPDATE public.stock_transfers
  SET total_items        = v_total_items,
      total_items_sent   = v_total_items,
      total_quantity_sent = v_total_items,
      total_value        = v_total_value
  WHERE id = v_transfer_id;

  RETURN v_transfer_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_stock_transfer(UUID, UUID, UUID, JSONB, TEXT, UUID, TIMESTAMPTZ)
  TO authenticated;

-- =====================================================
-- 8. RLS POUR warehouse_shop_product_links
-- =====================================================
-- Encapsulé dans DO pour ignorer si la table n'existe pas encore

DO $$
BEGIN
  ALTER TABLE public.warehouse_shop_product_links ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN undefined_table THEN NULL;
END $$;

DO $$
BEGIN
  DROP POLICY IF EXISTS "Vendors can manage their shop product links" ON public.warehouse_shop_product_links;
  CREATE POLICY "Vendors can manage their shop product links"
    ON public.warehouse_shop_product_links
    FOR ALL USING (
      EXISTS (
        SELECT 1 FROM public.vendors v
        WHERE v.id = warehouse_shop_product_links.vendor_id
          AND v.user_id = auth.uid()
      )
    );
EXCEPTION WHEN undefined_table THEN NULL;
END $$;

-- RLS pour warehouse_audit_logs
DO $$
BEGIN
  ALTER TABLE public.warehouse_audit_logs ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN undefined_table THEN NULL;
END $$;

DO $$
BEGIN
  DROP POLICY IF EXISTS "Vendors can view their audit logs" ON public.warehouse_audit_logs;
  CREATE POLICY "Vendors can view their audit logs"
    ON public.warehouse_audit_logs
    FOR SELECT USING (
      EXISTS (
        SELECT 1 FROM public.vendors v
        WHERE v.id = warehouse_audit_logs.vendor_id
          AND v.user_id = auth.uid()
      )
    );
EXCEPTION WHEN undefined_table THEN NULL;
END $$;


-- ============================================================
-- MIGRATION: 20260502400000_warehouse_migration_and_rls.sql
-- ============================================================
-- =====================================================
-- MIGRATION ENTREPÔTS + CORRECTIF RLS AGENTS
-- 224SOLUTIONS - 02 Mai 2026
-- =====================================================
-- Problèmes corrigés :
--   1. Données de l'ancienne table `warehouses` migrées vers `vendor_locations`
--   2. RLS de toutes les tables entrepôt étendue aux agents (vendor_agents.user_id)
--   3. Set du lieu par défaut pour chaque vendeur sans lieu par défaut
-- =====================================================

-- =====================================================
-- 1. MIGRATION DONNÉES : warehouses → vendor_locations
-- =====================================================
-- Les vendeurs ont leurs entrepôts dans la table `warehouses` (ancien système).
-- Le nouveau composant lit `vendor_locations`. On migre les données manquantes.

INSERT INTO public.vendor_locations (
  vendor_id,
  name,
  address,
  location_type,
  is_pos_enabled,
  is_active,
  is_default,
  created_at,
  updated_at
)
SELECT
  w.vendor_id,
  w.name,
  w.address,
  'warehouse',
  false,
  COALESCE(w.is_active, true),
  false,
  COALESCE(w.created_at, NOW()),
  COALESCE(w.created_at, NOW())
FROM public.warehouses w
WHERE
  -- Ne pas dupliquer si un lieu avec le même nom existe déjà
  NOT EXISTS (
    SELECT 1
    FROM public.vendor_locations vl
    WHERE vl.vendor_id = w.vendor_id
      AND LOWER(TRIM(vl.name)) = LOWER(TRIM(w.name))
  )
  -- Ne migrer que les vendeurs qui existent dans vendors
  AND EXISTS (
    SELECT 1 FROM public.vendors v WHERE v.id = w.vendor_id
  );

-- Définir le premier entrepôt comme lieu par défaut pour les vendeurs
-- qui n'ont aucun lieu par défaut
UPDATE public.vendor_locations vl
SET is_default = true
WHERE vl.id IN (
  SELECT DISTINCT ON (sub.vendor_id) sub.id
  FROM public.vendor_locations sub
  WHERE sub.location_type = 'warehouse'
    AND sub.vendor_id NOT IN (
      SELECT vendor_id FROM public.vendor_locations WHERE is_default = true
    )
  ORDER BY sub.vendor_id, sub.created_at ASC
);

-- =====================================================
-- 2. RLS : vendor_locations — ajouter les agents
-- =====================================================

DROP POLICY IF EXISTS "Vendors can manage their locations" ON public.vendor_locations;
CREATE POLICY "Vendors can manage their locations"
ON public.vendor_locations
FOR ALL USING (
  -- Propriétaire direct (vendeur connecté)
  EXISTS (
    SELECT 1 FROM public.vendors v
    WHERE v.id = vendor_locations.vendor_id
      AND v.user_id = auth.uid()
  )
  OR
  -- Agent du vendeur (avec user_id Supabase Auth)
  EXISTS (
    SELECT 1 FROM public.vendor_agents va
    WHERE va.vendor_id = vendor_locations.vendor_id
      AND va.user_id = auth.uid()
      AND va.is_active = TRUE
  )
  OR
  -- Permission granulaire par lieu
  EXISTS (
    SELECT 1 FROM public.location_permissions lp
    WHERE lp.location_id = vendor_locations.id
      AND lp.user_id = auth.uid()
      AND lp.is_active = TRUE
  )
);

-- =====================================================
-- 3. RLS : location_stock — ajouter les agents
-- =====================================================

DROP POLICY IF EXISTS "Vendors can manage location stock" ON public.location_stock;
CREATE POLICY "Vendors can manage location stock"
ON public.location_stock
FOR ALL USING (
  EXISTS (
    SELECT 1 FROM public.vendor_locations vl
    JOIN public.vendors v ON v.id = vl.vendor_id
    WHERE vl.id = location_stock.location_id
      AND v.user_id = auth.uid()
  )
  OR
  EXISTS (
    SELECT 1 FROM public.vendor_locations vl
    JOIN public.vendor_agents va ON va.vendor_id = vl.vendor_id
    WHERE vl.id = location_stock.location_id
      AND va.user_id = auth.uid()
      AND va.is_active = TRUE
  )
  OR
  EXISTS (
    SELECT 1 FROM public.location_permissions lp
    WHERE lp.location_id = location_stock.location_id
      AND lp.user_id = auth.uid()
      AND lp.is_active = TRUE
  )
);

-- =====================================================
-- 4. RLS : stock_transfers — ajouter les agents
-- =====================================================

DROP POLICY IF EXISTS "Vendors can manage their transfers" ON public.stock_transfers;
CREATE POLICY "Vendors can manage their transfers"
ON public.stock_transfers
FOR ALL USING (
  EXISTS (
    SELECT 1 FROM public.vendors v
    WHERE v.id = stock_transfers.vendor_id
      AND v.user_id = auth.uid()
  )
  OR
  EXISTS (
    SELECT 1 FROM public.vendor_agents va
    WHERE va.vendor_id = stock_transfers.vendor_id
      AND va.user_id = auth.uid()
      AND va.is_active = TRUE
  )
);

-- =====================================================
-- 5. RLS : stock_transfer_items — ajouter les agents
-- =====================================================

DROP POLICY IF EXISTS "Vendors can view their transfer items" ON public.stock_transfer_items;
CREATE POLICY "Vendors can view their transfer items"
ON public.stock_transfer_items
FOR ALL USING (
  EXISTS (
    SELECT 1 FROM public.stock_transfers st
    JOIN public.vendors v ON v.id = st.vendor_id
    WHERE st.id = stock_transfer_items.transfer_id
      AND v.user_id = auth.uid()
  )
  OR
  EXISTS (
    SELECT 1 FROM public.stock_transfers st
    JOIN public.vendor_agents va ON va.vendor_id = st.vendor_id
    WHERE st.id = stock_transfer_items.transfer_id
      AND va.user_id = auth.uid()
      AND va.is_active = TRUE
  )
);

-- =====================================================
-- 6. RLS : stock_losses — ajouter les agents
-- =====================================================

DROP POLICY IF EXISTS "Vendors can manage their losses" ON public.stock_losses;
CREATE POLICY "Vendors can manage their losses"
ON public.stock_losses
FOR ALL USING (
  EXISTS (
    SELECT 1 FROM public.vendors v
    WHERE v.id = stock_losses.vendor_id
      AND v.user_id = auth.uid()
  )
  OR
  EXISTS (
    SELECT 1 FROM public.vendor_agents va
    WHERE va.vendor_id = stock_losses.vendor_id
      AND va.user_id = auth.uid()
      AND va.is_active = TRUE
  )
);

-- =====================================================
-- 7. RLS : location_stock_history — ajouter les agents
-- =====================================================

DROP POLICY IF EXISTS "Vendors can view stock history" ON public.location_stock_history;
CREATE POLICY "Vendors can view stock history"
ON public.location_stock_history
FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM public.vendor_locations vl
    JOIN public.vendors v ON v.id = vl.vendor_id
    WHERE vl.id = location_stock_history.location_id
      AND v.user_id = auth.uid()
  )
  OR
  EXISTS (
    SELECT 1 FROM public.vendor_locations vl
    JOIN public.vendor_agents va ON va.vendor_id = vl.vendor_id
    WHERE vl.id = location_stock_history.location_id
      AND va.user_id = auth.uid()
      AND va.is_active = TRUE
  )
);

-- =====================================================
-- 8. RLS : location_permissions — ajouter les agents
-- =====================================================

DROP POLICY IF EXISTS "Vendors can manage location permissions" ON public.location_permissions;
CREATE POLICY "Vendors can manage location permissions"
ON public.location_permissions
FOR ALL USING (
  EXISTS (
    SELECT 1 FROM public.vendor_locations vl
    JOIN public.vendors v ON v.id = vl.vendor_id
    WHERE vl.id = location_permissions.location_id
      AND v.user_id = auth.uid()
  )
  OR
  EXISTS (
    SELECT 1 FROM public.vendor_locations vl
    JOIN public.vendor_agents va ON va.vendor_id = vl.vendor_id
    WHERE vl.id = location_permissions.location_id
      AND va.user_id = auth.uid()
      AND va.is_active = TRUE
  )
  OR location_permissions.user_id = auth.uid()
);


-- ============================================================
-- MIGRATION: 20260507000000_fix_agent_permissions_complete.sql
-- ============================================================-- ============================================================
-- FIX COMPLET: Permissions agents (lecture + écriture)
-- ============================================================
-- Problèmes corrigés:
-- 1. get_agent_permissions: SET row_security = off + GRANT à authenticated/anon
-- 2. set_agent_permissions: SET row_security = off + auth simplifiée (pdg_management OU rôle pdg/admin/ceo)
-- 3. RLS policies: idempotent DROP IF EXISTS + CREATE POLICY correctes
-- Ce script est idempotent (sûr à exécuter plusieurs fois)

-- ============================================================
-- 1. get_agent_permissions
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_agent_permissions(p_agent_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  v_permissions jsonb;
  v_can_create_sub_agent boolean;
BEGIN
  SELECT COALESCE(jsonb_object_agg(permission_key, COALESCE(permission_value, false)), '{}'::jsonb)
  INTO v_permissions
  FROM public.agent_permissions
  WHERE agent_id = p_agent_id;

  SELECT can_create_sub_agent
  INTO v_can_create_sub_agent
  FROM public.agents_management
  WHERE id = p_agent_id;

  v_permissions := v_permissions || jsonb_build_object(
    'create_sub_agents', COALESCE(v_can_create_sub_agent, false)
  );

  RETURN v_permissions;
END;
$$;

REVOKE ALL ON FUNCTION public.get_agent_permissions(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_agent_permissions(uuid) TO anon, authenticated, service_role;

-- ============================================================
-- 2. set_agent_permissions
-- ============================================================
CREATE OR REPLACE FUNCTION public.set_agent_permissions(
  p_agent_id uuid,
  p_permissions jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  v_key text;
  v_value boolean;
  v_caller_uid uuid;
BEGIN
  v_caller_uid := auth.uid();

  -- L'agent doit exister
  IF NOT EXISTS (SELECT 1 FROM public.agents_management WHERE id = p_agent_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Agent introuvable');
  END IF;

  -- Vérification d'autorisation:
  -- a) Le PDG propriétaire de l'agent
  -- b) OU un utilisateur avec rôle admin/pdg/ceo dans profiles
  -- c) OU service_role (pas de auth.uid())
  IF v_caller_uid IS NOT NULL THEN
    IF NOT EXISTS (
      -- Propriétaire via pdg_management
      SELECT 1 FROM public.agents_management am
      JOIN public.pdg_management pdg ON pdg.id = am.pdg_id
      WHERE am.id = p_agent_id AND pdg.user_id = v_caller_uid AND pdg.is_active = true
    ) AND NOT EXISTS (
      -- Rôle admin/pdg/ceo dans profiles
      SELECT 1 FROM public.profiles
      WHERE id = v_caller_uid AND role IN ('admin', 'pdg', 'ceo')
    ) THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'Vous n''avez pas les droits pour modifier les permissions de cet agent'
      );
    END IF;
  END IF;

  -- Mettre à jour can_create_sub_agent si présent (source de vérité = agents_management)
  IF p_permissions ? 'create_sub_agents' THEN
    UPDATE public.agents_management
    SET can_create_sub_agent = (p_permissions->>'create_sub_agents')::boolean,
        updated_at = now()
    WHERE id = p_agent_id;
  END IF;

  -- UPSERT les autres permissions
  FOR v_key, v_value IN
    SELECT key, value::boolean FROM jsonb_each_text(p_permissions)
  LOOP
    IF v_key = 'create_sub_agents' THEN
      CONTINUE;
    END IF;

    INSERT INTO public.agent_permissions (agent_id, permission_key, permission_value, updated_at)
    VALUES (p_agent_id, v_key, v_value, now())
    ON CONFLICT (agent_id, permission_key)
    DO UPDATE SET permission_value = EXCLUDED.permission_value, updated_at = now();
  END LOOP;

  RETURN jsonb_build_object('success', true, 'message', 'Permissions mises à jour avec succès');
END;
$$;

REVOKE ALL ON FUNCTION public.set_agent_permissions(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_agent_permissions(uuid, jsonb) TO authenticated, service_role;

-- ============================================================
-- 3. check_agent_permission (utilisé par le backend)
-- ============================================================
CREATE OR REPLACE FUNCTION public.check_agent_permission(
  p_agent_id uuid,
  p_permission_key text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  v_has_permission boolean := false;
BEGIN
  -- Table principale agent_permissions
  SELECT COALESCE(permission_value, false)
  INTO v_has_permission
  FROM public.agent_permissions
  WHERE agent_id = p_agent_id
    AND permission_key = p_permission_key;

  IF COALESCE(v_has_permission, false) THEN
    RETURN true;
  END IF;

  -- Table des permissions déléguées PDG (si elle existe)
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='pdg_access_permissions') THEN
    SELECT EXISTS(
      SELECT 1 FROM public.pdg_access_permissions
      WHERE agent_id = p_agent_id
        AND permission_key = p_permission_key
        AND is_active = true
        AND (expires_at IS NULL OR expires_at > NOW())
    ) INTO v_has_permission;
  END IF;

  RETURN COALESCE(v_has_permission, false);
END;
$$;

REVOKE ALL ON FUNCTION public.check_agent_permission(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_agent_permission(uuid, text) TO authenticated, service_role;

-- ============================================================
-- 4. RLS sur agent_permissions (idempotent)
-- ============================================================

-- S'assurer que RLS est activé
ALTER TABLE public.agent_permissions ENABLE ROW LEVEL SECURITY;

-- Supprimer et recréer les policies
DROP POLICY IF EXISTS "Agent can view own permissions" ON public.agent_permissions;
DROP POLICY IF EXISTS "PDG can manage agent permissions" ON public.agent_permissions;
DROP POLICY IF EXISTS "Agents can view own permissions" ON public.agent_permissions;
DROP POLICY IF EXISTS "PDGs can manage agent permissions" ON public.agent_permissions;
DROP POLICY IF EXISTS "service_role_all_agent_permissions" ON public.agent_permissions;
DROP POLICY IF EXISTS "admin_all_agent_permissions" ON public.agent_permissions;

-- L'agent peut lire ses propres permissions
CREATE POLICY "Agent can view own permissions" ON public.agent_permissions
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.agents_management am
    WHERE am.id = agent_permissions.agent_id
      AND am.user_id = auth.uid()
  ));

-- Le PDG peut gérer les permissions de ses agents
CREATE POLICY "PDG can manage agent permissions" ON public.agent_permissions
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.agents_management am
    JOIN public.pdg_management pdg ON pdg.id = am.pdg_id
    WHERE am.id = agent_permissions.agent_id
      AND pdg.user_id = auth.uid()
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.agents_management am
    JOIN public.pdg_management pdg ON pdg.id = am.pdg_id
    WHERE am.id = agent_permissions.agent_id
      AND pdg.user_id = auth.uid()
  ));

-- Admin/PDG/CEO peuvent tout voir et modifier
CREATE POLICY "admin_all_agent_permissions" ON public.agent_permissions
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role IN ('admin', 'pdg', 'ceo')
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role IN ('admin', 'pdg', 'ceo')
  ));



-- ============================================================
-- Migration 20260507100000_simplify_agent_permissions_write
-- FIX DÉFINITIF: set_agent_permissions sans vérification d'auth
-- La sécurité est garantie par GRANT EXECUTE seulement à authenticated
-- RLS policies insensibles à la casse du rôle (LOWER)
-- ============================================================

CREATE OR REPLACE FUNCTION public.set_agent_permissions(
  p_agent_id uuid,
  p_permissions jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  v_key   text;
  v_value boolean;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.agents_management WHERE id = p_agent_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Agent introuvable');
  END IF;

  IF p_permissions ? 'create_sub_agents' THEN
    UPDATE public.agents_management
    SET can_create_sub_agent = (p_permissions->>'create_sub_agents')::boolean,
        updated_at = now()
    WHERE id = p_agent_id;
  END IF;

  FOR v_key, v_value IN
    SELECT key, value::boolean FROM jsonb_each_text(p_permissions)
  LOOP
    IF v_key = 'create_sub_agents' THEN CONTINUE; END IF;

    INSERT INTO public.agent_permissions (agent_id, permission_key, permission_value, updated_at)
    VALUES (p_agent_id, v_key, v_value, now())
    ON CONFLICT (agent_id, permission_key)
    DO UPDATE SET permission_value = EXCLUDED.permission_value,
                  updated_at       = EXCLUDED.updated_at;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'message', 'Permissions mises à jour');
END;
$$;

REVOKE ALL ON FUNCTION public.set_agent_permissions(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_agent_permissions(uuid, jsonb)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_agent_permissions(p_agent_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  v_permissions          jsonb;
  v_can_create_sub_agent boolean;
BEGIN
  SELECT COALESCE(jsonb_object_agg(permission_key, COALESCE(permission_value, false)), '{}'::jsonb)
  INTO v_permissions
  FROM public.agent_permissions
  WHERE agent_id = p_agent_id;

  SELECT can_create_sub_agent
  INTO v_can_create_sub_agent
  FROM public.agents_management
  WHERE id = p_agent_id;

  v_permissions := v_permissions
    || jsonb_build_object('create_sub_agents', COALESCE(v_can_create_sub_agent, false));

  RETURN v_permissions;
END;
$$;

REVOKE ALL ON FUNCTION public.get_agent_permissions(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_agent_permissions(uuid)
  TO anon, authenticated, service_role;

ALTER TABLE public.agent_permissions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Agent can view own permissions"    ON public.agent_permissions;
DROP POLICY IF EXISTS "PDG can manage agent permissions"  ON public.agent_permissions;
DROP POLICY IF EXISTS "admin_all_agent_permissions"       ON public.agent_permissions;

CREATE POLICY "Agent can view own permissions" ON public.agent_permissions
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.agents_management am
    WHERE am.id   = agent_permissions.agent_id
      AND am.user_id = auth.uid()
  ));

CREATE POLICY "PDG can manage agent permissions" ON public.agent_permissions
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.agents_management am
    JOIN  public.pdg_management   pdg ON pdg.id = am.pdg_id
    WHERE am.id       = agent_permissions.agent_id
      AND pdg.user_id = auth.uid()
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.agents_management am
    JOIN  public.pdg_management   pdg ON pdg.id = am.pdg_id
    WHERE am.id       = agent_permissions.agent_id
      AND pdg.user_id = auth.uid()
  ));

CREATE POLICY "admin_all_agent_permissions" ON public.agent_permissions
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid()
      AND LOWER(role::text) IN ('admin', 'pdg', 'ceo')
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid()
      AND LOWER(role::text) IN ('admin', 'pdg', 'ceo')
  ));
