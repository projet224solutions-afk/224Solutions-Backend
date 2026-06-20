-- Table pour stocker les lots de tickets de transport générés
CREATE TABLE IF NOT EXISTS transport_ticket_batches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_number VARCHAR(50) NOT NULL UNIQUE,
    bureau_id UUID NOT NULL REFERENCES bureaus(id) ON DELETE CASCADE,
    ticket_config JSONB NOT NULL,
    start_number INTEGER NOT NULL,
    end_number INTEGER NOT NULL,
    tickets_count INTEGER NOT NULL DEFAULT 50,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    created_by UUID REFERENCES auth.users(id)
);

-- Index pour performance
CREATE INDEX idx_ticket_batches_bureau ON transport_ticket_batches(bureau_id);
CREATE INDEX idx_ticket_batches_created ON transport_ticket_batches(created_at DESC);

-- RLS
ALTER TABLE transport_ticket_batches ENABLE ROW LEVEL SECURITY;

-- Les bureaux peuvent voir leurs propres lots
CREATE POLICY "Bureaus can view own ticket batches"
ON transport_ticket_batches FOR SELECT
USING (
    bureau_id IN (
        SELECT id FROM bureaus 
        WHERE president_email = (SELECT email FROM auth.users WHERE id = auth.uid())
    )
);

-- Les bureaux peuvent créer des lots
CREATE POLICY "Bureaus can create ticket batches"
ON transport_ticket_batches FOR INSERT
WITH CHECK (
    bureau_id IN (
        SELECT id FROM bureaus 
        WHERE president_email = (SELECT email FROM auth.users WHERE id = auth.uid())
    )
);

-- Admins peuvent tout voir
CREATE POLICY "Admins can view all ticket batches"
ON transport_ticket_batches FOR SELECT
USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
);