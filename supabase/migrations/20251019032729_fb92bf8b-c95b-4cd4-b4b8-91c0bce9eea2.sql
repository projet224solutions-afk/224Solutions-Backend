-- Add manager fields to warehouses table
ALTER TABLE warehouses 
ADD COLUMN IF NOT EXISTS manager_name VARCHAR(100),
ADD COLUMN IF NOT EXISTS manager_phone VARCHAR(20),
ADD COLUMN IF NOT EXISTS manager_email VARCHAR(100);