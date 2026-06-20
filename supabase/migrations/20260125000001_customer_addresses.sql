-- Migration: customer_addresses table
-- Description: Table des adresses de livraison des clients
-- Created: 2026-01-25
-- 224SOLUTIONS - Vista Flows

-- Table des adresses de livraison des clients
CREATE TABLE IF NOT EXISTS public.customer_addresses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  label VARCHAR(50) NOT NULL DEFAULT 'domicile',
  recipient_name VARCHAR(255) NOT NULL,
  phone VARCHAR(50) NOT NULL,
  address_line_1 TEXT NOT NULL,
  address_line_2 TEXT,
  city VARCHAR(100) NOT NULL,
  region VARCHAR(100),
  postal_code VARCHAR(20),
  country VARCHAR(2) NOT NULL DEFAULT 'BJ',
  is_default BOOLEAN DEFAULT false,
  delivery_instructions TEXT,
  latitude DECIMAL(10, 8),
  longitude DECIMAL(11, 8),
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Index pour les recherches fréquentes
CREATE INDEX IF NOT EXISTS idx_customer_addresses_user_id ON public.customer_addresses(user_id);
CREATE INDEX IF NOT EXISTS idx_customer_addresses_is_default ON public.customer_addresses(user_id, is_default);

-- Contrainte pour s'assurer qu'il n'y a qu'une seule adresse par défaut par utilisateur
CREATE UNIQUE INDEX IF NOT EXISTS idx_customer_addresses_single_default 
ON public.customer_addresses(user_id) 
WHERE is_default = true;

-- Enable RLS
ALTER TABLE public.customer_addresses ENABLE ROW LEVEL SECURITY;

-- Policy: Les utilisateurs peuvent voir leurs propres adresses
CREATE POLICY "Users can view own addresses"
ON public.customer_addresses
FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

-- Policy: Les utilisateurs peuvent créer leurs propres adresses
CREATE POLICY "Users can create own addresses"
ON public.customer_addresses
FOR INSERT
TO authenticated
WITH CHECK (auth.uid() = user_id);

-- Policy: Les utilisateurs peuvent modifier leurs propres adresses
CREATE POLICY "Users can update own addresses"
ON public.customer_addresses
FOR UPDATE
TO authenticated
USING (auth.uid() = user_id)
WITH CHECK (auth.uid() = user_id);

-- Policy: Les utilisateurs peuvent supprimer leurs propres adresses
CREATE POLICY "Users can delete own addresses"
ON public.customer_addresses
FOR DELETE
TO authenticated
USING (auth.uid() = user_id);

-- Policy: Les vendeurs peuvent voir les adresses des clients qui ont commandé chez eux
CREATE POLICY "Vendors can view customer addresses for orders"
ON public.customer_addresses
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.orders o
    JOIN public.order_items oi ON oi.order_id = o.id
    JOIN public.products p ON p.id = oi.product_id
    WHERE o.customer_id = customer_addresses.user_id
    AND p.vendor_id = auth.uid()
  )
);

-- Trigger pour mettre à jour updated_at
CREATE OR REPLACE FUNCTION update_customer_addresses_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS customer_addresses_updated_at ON public.customer_addresses;
CREATE TRIGGER customer_addresses_updated_at
  BEFORE UPDATE ON public.customer_addresses
  FOR EACH ROW
  EXECUTE FUNCTION update_customer_addresses_updated_at();

-- Fonction pour s'assurer qu'il n'y a qu'une seule adresse par défaut
CREATE OR REPLACE FUNCTION ensure_single_default_address()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.is_default = true THEN
    UPDATE public.customer_addresses
    SET is_default = false
    WHERE user_id = NEW.user_id
    AND id != NEW.id
    AND is_default = true;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS ensure_single_default_address_trigger ON public.customer_addresses;
CREATE TRIGGER ensure_single_default_address_trigger
  BEFORE INSERT OR UPDATE ON public.customer_addresses
  FOR EACH ROW
  EXECUTE FUNCTION ensure_single_default_address();

-- Commentaires sur la table
COMMENT ON TABLE public.customer_addresses IS 'Adresses de livraison des clients';
COMMENT ON COLUMN public.customer_addresses.label IS 'Type d''adresse: domicile, bureau, travail, autre';
COMMENT ON COLUMN public.customer_addresses.recipient_name IS 'Nom du destinataire';
COMMENT ON COLUMN public.customer_addresses.phone IS 'Numéro de téléphone pour la livraison';
COMMENT ON COLUMN public.customer_addresses.is_default IS 'Adresse par défaut pour les livraisons';
COMMENT ON COLUMN public.customer_addresses.delivery_instructions IS 'Instructions spéciales pour le livreur';
COMMENT ON COLUMN public.customer_addresses.latitude IS 'Latitude GPS de l''adresse';
COMMENT ON COLUMN public.customer_addresses.longitude IS 'Longitude GPS de l''adresse';
