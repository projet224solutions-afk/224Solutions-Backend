-- Add tax_enabled column to pos_settings table
ALTER TABLE public.pos_settings 
ADD COLUMN tax_enabled BOOLEAN NOT NULL DEFAULT true;