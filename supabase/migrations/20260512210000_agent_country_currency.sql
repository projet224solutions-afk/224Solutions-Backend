-- Add country/currency fields to agents_management
ALTER TABLE agents_management
  ADD COLUMN IF NOT EXISTS country_code VARCHAR(2) DEFAULT 'GN',
  ADD COLUMN IF NOT EXISTS country_name VARCHAR(100) DEFAULT 'Guinée',
  ADD COLUMN IF NOT EXISTS currency VARCHAR(3) DEFAULT 'GNF';

-- Add country_code to profiles for per-user currency resolution
ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS country_code VARCHAR(2);

-- Back-fill existing agents with default Guinea values
UPDATE agents_management
SET
  country_code = 'GN',
  country_name = 'Guinée',
  currency = 'GNF'
WHERE country_code IS NULL OR country_code = '';
