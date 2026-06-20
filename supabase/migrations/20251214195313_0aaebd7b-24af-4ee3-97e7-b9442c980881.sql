-- Add logo_url column to pos_settings table
ALTER TABLE public.pos_settings 
ADD COLUMN IF NOT EXISTS logo_url TEXT;