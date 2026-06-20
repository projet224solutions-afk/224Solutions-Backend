-- Fix stripe_wallets trigger: add missing "status" column
ALTER TABLE public.stripe_wallets
ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'ACTIVE';

UPDATE public.stripe_wallets
SET status = 'ACTIVE'
WHERE status IS NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'stripe_wallets_status_check'
  ) THEN
    ALTER TABLE public.stripe_wallets
    ADD CONSTRAINT stripe_wallets_status_check
    CHECK (status IN ('ACTIVE','SUSPENDED','CLOSED'));
  END IF;
END$$;