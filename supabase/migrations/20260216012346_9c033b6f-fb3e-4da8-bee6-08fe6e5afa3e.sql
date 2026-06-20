-- Insert international transfer fee setting (default 1%)
INSERT INTO public.pdg_settings (setting_key, setting_value, updated_at)
SELECT 'international_transfer_fee_percentage', '1', now()
WHERE NOT EXISTS (
  SELECT 1 FROM public.pdg_settings WHERE setting_key = 'international_transfer_fee_percentage'
);