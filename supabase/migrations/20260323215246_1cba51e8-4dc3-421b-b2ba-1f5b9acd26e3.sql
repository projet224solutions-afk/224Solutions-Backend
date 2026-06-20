DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_schema = 'public' 
    AND table_name = 'currency_exchange_rates' 
    AND column_name = 'source_type'
  ) THEN
    ALTER TABLE public.currency_exchange_rates 
      ADD COLUMN source_type text DEFAULT 'fallback_api';
    COMMENT ON COLUMN public.currency_exchange_rates.source_type IS 
      'Type de source: official_html, official_fixed_parity, official_cross, fallback_api';
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_schema = 'public' 
    AND table_name = 'fx_collection_log' 
    AND column_name = 'source_type'
  ) THEN
    ALTER TABLE public.fx_collection_log 
      ADD COLUMN source_type text DEFAULT 'fallback_api';
    COMMENT ON COLUMN public.fx_collection_log.source_type IS 
      'Type de source: official_html, official_fixed_parity, official_cross, fallback_api';
  END IF;
END $$;