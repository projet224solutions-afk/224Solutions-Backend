-- Update default margin from 3% (0.03) to 4% (0.04)
-- This affects all currency exchange rates applied globally

UPDATE public.margin_config
SET 
  config_value = 0.04,
  description = 'Marge par défaut de 4% appliquée sur les taux officiels',
  updated_at = now()
WHERE config_key = 'default_margin';

-- Log the change for audit trail
INSERT INTO public.fx_collection_log (
  collection_date,
  source_type,
  source_url,
  status,
  rates_count,
  error_message,
  attempt_number,
  created_at
) VALUES (
  CURRENT_DATE,
  'configuration_update',
  'margin_config',
  'completed',
  1,
  'Margin updated from 3% to 4%',
  1,
  now()
) ON CONFLICT DO NOTHING;
