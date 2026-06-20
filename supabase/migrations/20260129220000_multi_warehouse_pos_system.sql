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

-- Ajouter available_quantity si elle n'existe pas (AVANT les index)
ALTER TABLE public.location_stock ADD COLUMN IF NOT EXISTS available_quantity INTEGER DEFAULT 0;

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

-- Ajouter colonnes calculées si elles n'existent pas (AVANT les index)
ALTER TABLE public.stock_transfer_items ADD COLUMN IF NOT EXISTS quantity_missing INTEGER DEFAULT 0;
ALTER TABLE public.stock_transfer_items ADD COLUMN IF NOT EXISTS total_value DECIMAL(15,2) DEFAULT 0;

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

-- Ajouter la colonne location_id aux commandes
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS location_id UUID REFERENCES public.vendor_locations(id);
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS pos_cashier_id UUID REFERENCES auth.users(id);

CREATE INDEX IF NOT EXISTS idx_orders_location ON orders(location_id);

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
INSERT INTO vendor_locations (vendor_id, name, code, location_type, is_default, address, contact_person, contact_phone, created_at)
SELECT 
  w.vendor_id,
  w.name,
  'ENT' || ROW_NUMBER() OVER (PARTITION BY w.vendor_id ORDER BY w.created_at),
  'warehouse',
  ROW_NUMBER() OVER (PARTITION BY w.vendor_id ORDER BY w.created_at) = 1,
  w.address,
  w.contact_person,
  w.contact_phone,
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

COMMENT ON FUNCTION create_stock_transfer IS 'Crée un nouveau transfert de stock avec validation';
COMMENT ON FUNCTION ship_transfer IS 'Expédie un transfert (passe en transit et décrémente le stock source)';
COMMENT ON FUNCTION confirm_transfer_reception IS 'Confirme la réception avec gestion des manquants';
