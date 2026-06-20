-- Migration: Convert vendor_agents permissions from string[] to JSONB
-- This allows storing structured permission objects for each agent

BEGIN;

-- 1. Add new JSONB column for permissions
ALTER TABLE public.vendor_agents 
ADD COLUMN IF NOT EXISTS permissions_jsonb JSONB DEFAULT '{
  "view_dashboard": true,
  "view_analytics": false,
  "access_pos": false,
  "manage_products": false,
  "manage_orders": false,
  "manage_inventory": false,
  "manage_warehouse": false,
  "manage_suppliers": false,
  "manage_agents": false,
  "manage_clients": false,
  "manage_prospects": false,
  "manage_marketing": false,
  "access_wallet": false,
  "manage_payments": false,
  "manage_payment_links": false,
  "manage_expenses": false,
  "manage_debts": false,
  "access_affiliate": false,
  "manage_delivery": false,
  "access_support": false,
  "access_communication": true,
  "view_reports": false,
  "access_settings": false
}'::jsonb;

-- 2. Migrate existing data: convert string array to JSONB object
-- For existing agents, we'll set all permissions from the array to true
UPDATE public.vendor_agents
SET permissions_jsonb = (
  SELECT jsonb_object_agg(perm, true)
  FROM unnest(permissions) AS perm
)
WHERE permissions IS NOT NULL AND array_length(permissions, 1) > 0;

-- 3. Drop old permissions column
ALTER TABLE public.vendor_agents 
DROP COLUMN IF EXISTS permissions;

-- 4. Rename new column to permissions
ALTER TABLE public.vendor_agents 
RENAME COLUMN permissions_jsonb TO permissions;

-- 5. Update the trigger function to handle JSONB permissions
CREATE OR REPLACE FUNCTION public.set_vendor_agent_defaults()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
BEGIN
  -- Generate agent_code if not provided
  IF NEW.agent_code IS NULL OR NEW.agent_code = '' THEN
    NEW.agent_code := public.generate_vendor_agent_code();
  END IF;

  -- Generate access_token if not provided
  IF NEW.access_token IS NULL OR NEW.access_token = '' THEN
    NEW.access_token := public.generate_vendor_agent_access_token();
  END IF;

  -- Set default permissions if not provided (as JSONB)
  IF NEW.permissions IS NULL THEN
    NEW.permissions := '{
      "view_dashboard": true,
      "view_analytics": false,
      "access_pos": false,
      "manage_products": false,
      "manage_orders": false,
      "manage_inventory": false,
      "manage_warehouse": false,
      "manage_suppliers": false,
      "manage_agents": false,
      "manage_clients": false,
      "manage_prospects": false,
      "manage_marketing": false,
      "access_wallet": false,
      "manage_payments": false,
      "manage_payment_links": false,
      "manage_expenses": false,
      "manage_debts": false,
      "access_affiliate": false,
      "manage_delivery": false,
      "access_support": false,
      "access_communication": true,
      "view_reports": false,
      "access_settings": false
    }'::jsonb;
  END IF;

  -- Set default values
  IF NEW.is_active IS NULL THEN
    NEW.is_active := true;
  END IF;

  IF NEW.can_create_sub_agent IS NULL THEN
    NEW.can_create_sub_agent := false;
  END IF;

  NEW.created_at := now();
  NEW.updated_at := now();

  RETURN NEW;
END;
$$;

COMMIT;