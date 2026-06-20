-- Fix escrow_transactions status constraint to include 'held'
-- Drop the old constraint
ALTER TABLE public.escrow_transactions 
  DROP CONSTRAINT IF EXISTS escrow_transactions_status_check;

-- Add the updated constraint with all required statuses
ALTER TABLE public.escrow_transactions 
  ADD CONSTRAINT escrow_transactions_status_check 
  CHECK (status IN ('pending', 'held', 'released', 'refunded', 'dispute'));