-- Allow anyone (authenticated or anonymous) to read vendor certification status
CREATE POLICY "Anyone can read vendor certifications"
  ON public.vendor_certifications
  FOR SELECT
  TO public
  USING (true);