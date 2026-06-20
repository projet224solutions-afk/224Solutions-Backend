-- Add 'ceo' to the user_role enum to support CEO role in escrow operations
ALTER TYPE public.user_role ADD VALUE IF NOT EXISTS 'ceo';