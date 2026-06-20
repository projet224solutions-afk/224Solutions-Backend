-- Créer la table devis_requests pour les demandes de devis
CREATE TABLE IF NOT EXISTS public.devis_requests (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  service_type TEXT NOT NULL,
  description TEXT NOT NULL,
  first_name TEXT,
  last_name TEXT,
  email TEXT NOT NULL,
  phone TEXT,
  budget NUMERIC,
  status TEXT NOT NULL DEFAULT 'pending',
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  responded_at TIMESTAMP WITH TIME ZONE,
  response TEXT
);

-- Enable RLS
ALTER TABLE public.devis_requests ENABLE ROW LEVEL SECURITY;

-- Policy: Anyone can insert a devis request
CREATE POLICY "Anyone can create devis request"
  ON public.devis_requests
  FOR INSERT
  WITH CHECK (true);

-- Policy: Admins can view all devis requests
CREATE POLICY "Admins can view all devis requests"
  ON public.devis_requests
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM profiles
      WHERE profiles.id = auth.uid()
      AND profiles.role = 'admin'
    )
  );

-- Policy: Admins can update devis requests
CREATE POLICY "Admins can update devis requests"
  ON public.devis_requests
  FOR UPDATE
  USING (
    EXISTS (
      SELECT 1 FROM profiles
      WHERE profiles.id = auth.uid()
      AND profiles.role = 'admin'
    )
  );

-- Create index for faster queries
CREATE INDEX idx_devis_requests_status ON public.devis_requests(status);
CREATE INDEX idx_devis_requests_created_at ON public.devis_requests(created_at DESC);

-- Add trigger for updated_at
CREATE OR REPLACE FUNCTION update_devis_requests_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_devis_requests_updated_at_trigger
  BEFORE UPDATE ON public.devis_requests
  FOR EACH ROW
  EXECUTE FUNCTION update_devis_requests_updated_at();