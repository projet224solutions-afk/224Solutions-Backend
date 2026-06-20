-- Add user_id to vendor_agents table for Supabase Auth integration
ALTER TABLE public.vendor_agents 
ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL;

-- Add password_hash for local authentication (backup)
ALTER TABLE public.vendor_agents 
ADD COLUMN IF NOT EXISTS password_hash TEXT;

-- Add user_id to bureaus table for Supabase Auth integration  
ALTER TABLE public.bureaus
ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL;

-- Add password_hash for bureaus
ALTER TABLE public.bureaus
ADD COLUMN IF NOT EXISTS password_hash TEXT;

-- Create index for faster lookups
CREATE INDEX IF NOT EXISTS idx_vendor_agents_user_id ON public.vendor_agents(user_id);
CREATE INDEX IF NOT EXISTS idx_vendor_agents_email ON public.vendor_agents(email);
CREATE INDEX IF NOT EXISTS idx_bureaus_user_id ON public.bureaus(user_id);
CREATE INDEX IF NOT EXISTS idx_bureaus_president_email ON public.bureaus(president_email);