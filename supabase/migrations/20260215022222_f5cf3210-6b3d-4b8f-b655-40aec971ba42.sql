-- Allow all authenticated users to read deposit/withdrawal fee settings
CREATE POLICY "Authenticated users can read fee settings"
ON public.pdg_settings
FOR SELECT
TO authenticated
USING (setting_key IN ('deposit_fee_percentage', 'withdrawal_fee_percentage'));