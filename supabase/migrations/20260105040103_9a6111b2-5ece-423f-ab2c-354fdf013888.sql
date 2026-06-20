-- Create vendor_certifications table
CREATE TABLE IF NOT EXISTS public.vendor_certifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE UNIQUE,
  status TEXT NOT NULL DEFAULT 'NON_CERTIFIE' CHECK (status IN ('NON_CERTIFIE', 'CERTIFIE', 'SUSPENDU')),
  verified_by UUID REFERENCES auth.users(id),
  verified_at TIMESTAMPTZ,
  kyc_verified_at TIMESTAMPTZ,
  kyc_status TEXT DEFAULT 'pending',
  last_status_change TIMESTAMPTZ NOT NULL DEFAULT now(),
  internal_notes TEXT,
  rejection_reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.vendor_certifications ENABLE ROW LEVEL SECURITY;

-- Policy: Admins can read all certifications
CREATE POLICY "Admins can read all certifications"
  ON public.vendor_certifications
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles 
      WHERE id = auth.uid() AND role = 'admin'::user_role
    )
  );

-- Policy: Admins can insert certifications
CREATE POLICY "Admins can insert certifications"
  ON public.vendor_certifications
  FOR INSERT
  TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.profiles 
      WHERE id = auth.uid() AND role = 'admin'::user_role
    )
  );

-- Policy: Admins can update certifications
CREATE POLICY "Admins can update certifications"
  ON public.vendor_certifications
  FOR UPDATE
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles 
      WHERE id = auth.uid() AND role = 'admin'::user_role
    )
  );

-- Policy: Vendors can read their own certification
CREATE POLICY "Vendors can read own certification"
  ON public.vendor_certifications
  FOR SELECT
  TO authenticated
  USING (vendor_id = auth.uid());

-- Trigger for updated_at
CREATE TRIGGER update_vendor_certifications_updated_at
  BEFORE UPDATE ON public.vendor_certifications
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

-- Create indexes
CREATE INDEX idx_vendor_certifications_vendor_id ON public.vendor_certifications(vendor_id);
CREATE INDEX idx_vendor_certifications_status ON public.vendor_certifications(status);