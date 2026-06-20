-- Table contracts
CREATE TABLE IF NOT EXISTS contracts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  client_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  client_name TEXT NOT NULL,
  client_email TEXT,
  client_phone TEXT,
  client_info TEXT,
  contract_type TEXT NOT NULL CHECK (contract_type IN (
    'vente_achat',
    'livraison',
    'prestation',
    'agent_sous_agent',
    'service',
    'entreprise_partenaire'
  )),
  custom_fields JSONB,
  contract_content TEXT NOT NULL,
  amount DECIMAL(12,2),
  vendor_logo_url TEXT,
  vendor_signature_url TEXT,
  client_signature_url TEXT,
  pdf_url TEXT,
  status TEXT NOT NULL DEFAULT 'created' CHECK (status IN ('created', 'sent', 'signed', 'archived')),
  signed_at TIMESTAMP,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_contracts_vendor_id ON contracts(vendor_id);
CREATE INDEX idx_contracts_client_id ON contracts(client_id);
CREATE INDEX idx_contracts_status ON contracts(status);

-- Enable RLS
ALTER TABLE contracts ENABLE ROW LEVEL SECURITY;

-- RLS Policies
CREATE POLICY "Vendors can view their own contracts"
  ON contracts FOR SELECT
  USING (auth.uid() = vendor_id);

CREATE POLICY "Clients can view their contracts"
  ON contracts FOR SELECT
  USING (auth.uid() = client_id);

CREATE POLICY "Admin can view all contracts"
  ON contracts FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM profiles
      WHERE profiles.id = auth.uid() AND profiles.role = 'admin'
    )
  );

CREATE POLICY "Vendors can create contracts"
  ON contracts FOR INSERT
  WITH CHECK (auth.uid() = vendor_id);

CREATE POLICY "Vendors can update their own contracts"
  ON contracts FOR UPDATE
  USING (auth.uid() = vendor_id);

CREATE POLICY "Clients can update signature on their contracts"
  ON contracts FOR UPDATE
  USING (auth.uid() = client_id)
  WITH CHECK (auth.uid() = client_id);

-- Function to update timestamp
CREATE OR REPLACE FUNCTION update_contracts_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_update_contracts_updated_at
  BEFORE UPDATE ON contracts
  FOR EACH ROW
  EXECUTE FUNCTION update_contracts_updated_at();