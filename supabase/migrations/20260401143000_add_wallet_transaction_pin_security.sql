-- Wallet transaction PIN security for sensitive operations
-- Adds 6-digit transaction PIN support with lockout tracking

ALTER TABLE public.wallets
  ADD COLUMN IF NOT EXISTS pin_enabled BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS pin_failed_attempts INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS pin_locked_until TIMESTAMPTZ NULL,
  ADD COLUMN IF NOT EXISTS pin_updated_at TIMESTAMPTZ NULL;

COMMENT ON COLUMN public.wallets.pin_hash IS 'Hashed transaction PIN (scrypt salt:hash format)';
COMMENT ON COLUMN public.wallets.pin_enabled IS 'Whether a transaction PIN is required for transfers/withdrawals';
COMMENT ON COLUMN public.wallets.pin_failed_attempts IS 'Consecutive failed PIN attempts';
COMMENT ON COLUMN public.wallets.pin_locked_until IS 'Temporary lockout expiration after too many failed attempts';
COMMENT ON COLUMN public.wallets.pin_updated_at IS 'Last time the transaction PIN was configured/changed';
