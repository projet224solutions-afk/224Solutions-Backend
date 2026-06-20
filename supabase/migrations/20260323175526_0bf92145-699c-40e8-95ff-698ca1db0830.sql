
-- Add unique constraint for upsert on currency_exchange_rates
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'uq_currency_exchange_rates_pair'
  ) THEN
    ALTER TABLE public.currency_exchange_rates 
    ADD CONSTRAINT uq_currency_exchange_rates_pair UNIQUE (from_currency, to_currency);
  END IF;
END $$;
