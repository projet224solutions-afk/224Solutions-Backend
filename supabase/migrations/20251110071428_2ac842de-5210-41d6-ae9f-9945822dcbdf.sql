-- Création de la table des expéditions logistiques
CREATE TABLE IF NOT EXISTS shipments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tracking_number TEXT NOT NULL UNIQUE,
  vendor_id UUID NOT NULL,
  
  -- Expéditeur
  sender_name TEXT NOT NULL,
  sender_phone TEXT NOT NULL,
  sender_address TEXT NOT NULL,
  
  -- Destinataire
  receiver_name TEXT NOT NULL,
  receiver_phone TEXT NOT NULL,
  receiver_address TEXT NOT NULL,
  
  -- Détails du colis
  weight NUMERIC NOT NULL DEFAULT 0,
  pieces_count INTEGER NOT NULL DEFAULT 1,
  item_type TEXT,
  package_description TEXT,
  
  -- Options
  cash_on_delivery BOOLEAN DEFAULT false,
  cod_amount NUMERIC DEFAULT 0,
  insurance BOOLEAN DEFAULT false,
  insurance_amount NUMERIC DEFAULT 0,
  return_option BOOLEAN DEFAULT false,
  
  -- Statut et tracking
  status TEXT NOT NULL DEFAULT 'created',
  current_location TEXT,
  
  -- Métadonnées
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  pickup_date TIMESTAMPTZ,
  delivery_date TIMESTAMPTZ,
  
  CONSTRAINT shipments_vendor_id_fkey FOREIGN KEY (vendor_id) REFERENCES vendors(id) ON DELETE CASCADE
);

-- Index pour performance
CREATE INDEX IF NOT EXISTS idx_shipments_vendor_id ON shipments(vendor_id);
CREATE INDEX IF NOT EXISTS idx_shipments_tracking_number ON shipments(tracking_number);
CREATE INDEX IF NOT EXISTS idx_shipments_status ON shipments(status);
CREATE INDEX IF NOT EXISTS idx_shipments_created_at ON shipments(created_at DESC);

-- Table pour le suivi détaillé des expéditions
CREATE TABLE IF NOT EXISTS shipment_tracking (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shipment_id UUID NOT NULL,
  status TEXT NOT NULL,
  title TEXT NOT NULL,
  description TEXT,
  location TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  
  CONSTRAINT shipment_tracking_shipment_id_fkey FOREIGN KEY (shipment_id) REFERENCES shipments(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_shipment_tracking_shipment_id ON shipment_tracking(shipment_id);
CREATE INDEX IF NOT EXISTS idx_shipment_tracking_created_at ON shipment_tracking(created_at);

-- Fonction pour générer un numéro de suivi unique (format: JYM + 12 chiffres)
CREATE OR REPLACE FUNCTION generate_tracking_number()
RETURNS TEXT AS $$
DECLARE
  tracking_num TEXT;
  exists_check BOOLEAN;
BEGIN
  LOOP
    -- Générer un nombre aléatoire de 12 chiffres
    tracking_num := 'JYM' || LPAD(FLOOR(RANDOM() * 1000000000000)::TEXT, 12, '0');
    
    -- Vérifier si ce numéro existe déjà
    SELECT EXISTS(SELECT 1 FROM shipments WHERE tracking_number = tracking_num) INTO exists_check;
    
    -- Si le numéro n'existe pas, on sort de la boucle
    EXIT WHEN NOT exists_check;
  END LOOP;
  
  RETURN tracking_num;
END;
$$ LANGUAGE plpgsql;

-- Trigger pour auto-générer le tracking number
CREATE OR REPLACE FUNCTION set_tracking_number()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.tracking_number IS NULL OR NEW.tracking_number = '' THEN
    NEW.tracking_number := generate_tracking_number();
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_set_tracking_number
BEFORE INSERT ON shipments
FOR EACH ROW
EXECUTE FUNCTION set_tracking_number();

-- Trigger pour mettre à jour updated_at
CREATE OR REPLACE FUNCTION update_shipment_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_update_shipment_updated_at
BEFORE UPDATE ON shipments
FOR EACH ROW
EXECUTE FUNCTION update_shipment_updated_at();

-- Trigger pour créer automatiquement un premier événement de tracking
CREATE OR REPLACE FUNCTION create_initial_tracking()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO shipment_tracking (shipment_id, status, title, description, location)
  VALUES (
    NEW.id,
    'created',
    'Commande créée',
    'Votre expédition a été enregistrée avec succès',
    NEW.sender_address
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_create_initial_tracking
AFTER INSERT ON shipments
FOR EACH ROW
EXECUTE FUNCTION create_initial_tracking();

-- RLS Policies
ALTER TABLE shipments ENABLE ROW LEVEL SECURITY;
ALTER TABLE shipment_tracking ENABLE ROW LEVEL SECURITY;

-- Les vendeurs peuvent voir et gérer leurs propres expéditions
CREATE POLICY "Vendors can view their own shipments"
  ON shipments FOR SELECT
  USING (
    vendor_id IN (
      SELECT id FROM vendors WHERE user_id = auth.uid()
    )
  );

CREATE POLICY "Vendors can create shipments"
  ON shipments FOR INSERT
  WITH CHECK (
    vendor_id IN (
      SELECT id FROM vendors WHERE user_id = auth.uid()
    )
  );

CREATE POLICY "Vendors can update their own shipments"
  ON shipments FOR UPDATE
  USING (
    vendor_id IN (
      SELECT id FROM vendors WHERE user_id = auth.uid()
    )
  );

CREATE POLICY "Vendors can delete their own shipments"
  ON shipments FOR DELETE
  USING (
    vendor_id IN (
      SELECT id FROM vendors WHERE user_id = auth.uid()
    )
  );

-- Policies pour le tracking
CREATE POLICY "Users can view tracking for their shipments"
  ON shipment_tracking FOR SELECT
  USING (
    shipment_id IN (
      SELECT id FROM shipments WHERE vendor_id IN (
        SELECT id FROM vendors WHERE user_id = auth.uid()
      )
    )
  );

CREATE POLICY "System can insert tracking"
  ON shipment_tracking FOR INSERT
  WITH CHECK (true);

CREATE POLICY "Vendors can update tracking"
  ON shipment_tracking FOR UPDATE
  USING (
    shipment_id IN (
      SELECT id FROM shipments WHERE vendor_id IN (
        SELECT id FROM vendors WHERE user_id = auth.uid()
      )
    )
  );