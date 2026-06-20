-- Add missing columns to stock_movements if they don't exist
DO $$ 
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'stock_movements' AND column_name = 'created_by') THEN
    ALTER TABLE stock_movements ADD COLUMN created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL;
  END IF;
END $$;

-- Create warehouse_permissions table
CREATE TABLE IF NOT EXISTS warehouse_permissions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  warehouse_id UUID NOT NULL REFERENCES warehouses(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  can_view BOOLEAN DEFAULT true,
  can_edit BOOLEAN DEFAULT false,
  can_manage_stock BOOLEAN DEFAULT false,
  can_transfer BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(warehouse_id, user_id)
);

-- Enable RLS on new tables
ALTER TABLE warehouse_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_movements ENABLE ROW LEVEL SECURITY;

-- Drop and recreate policies
DROP POLICY IF EXISTS "Vendors can manage their warehouse permissions" ON warehouse_permissions;
DROP POLICY IF EXISTS "Users can view their own permissions" ON warehouse_permissions;
DROP POLICY IF EXISTS "Vendors can view their warehouse movements" ON stock_movements;
DROP POLICY IF EXISTS "Authorized users can create stock movements" ON stock_movements;

-- RLS Policies for warehouse_permissions
CREATE POLICY "Vendors can manage their warehouse permissions"
  ON warehouse_permissions FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM warehouses w
      JOIN vendors v ON w.vendor_id = v.id
      WHERE w.id = warehouse_permissions.warehouse_id
      AND v.user_id = auth.uid()
    )
  );

CREATE POLICY "Users can view their own permissions"
  ON warehouse_permissions FOR SELECT
  USING (user_id = auth.uid());

-- RLS Policies for stock_movements
CREATE POLICY "Vendors can view their warehouse movements"
  ON stock_movements FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM warehouses w
      JOIN vendors v ON w.vendor_id = v.id
      WHERE (w.id = stock_movements.from_warehouse_id OR w.id = stock_movements.to_warehouse_id)
      AND v.user_id = auth.uid()
    )
  );

CREATE POLICY "Authorized users can create stock movements"
  ON stock_movements FOR INSERT
  WITH CHECK (
    auth.uid() = created_by
    AND (
      EXISTS (
        SELECT 1 FROM warehouse_permissions wp
        WHERE wp.warehouse_id = stock_movements.from_warehouse_id
        AND wp.user_id = auth.uid()
        AND wp.can_manage_stock = true
      )
      OR EXISTS (
        SELECT 1 FROM warehouse_permissions wp
        WHERE wp.warehouse_id = stock_movements.to_warehouse_id
        AND wp.user_id = auth.uid()
        AND wp.can_manage_stock = true
      )
      OR EXISTS (
        SELECT 1 FROM warehouses w
        JOIN vendors v ON w.vendor_id = v.id
        WHERE (w.id = stock_movements.from_warehouse_id OR w.id = stock_movements.to_warehouse_id)
        AND v.user_id = auth.uid()
      )
    )
  );

-- Create indexes for performance
DO $$ 
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_warehouse_permissions_user') THEN
    CREATE INDEX idx_warehouse_permissions_user ON warehouse_permissions(user_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_warehouse_permissions_warehouse') THEN
    CREATE INDEX idx_warehouse_permissions_warehouse ON warehouse_permissions(warehouse_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_stock_movements_from') THEN
    CREATE INDEX idx_stock_movements_from ON stock_movements(from_warehouse_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_stock_movements_to') THEN
    CREATE INDEX idx_stock_movements_to ON stock_movements(to_warehouse_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_stock_movements_product') THEN
    CREATE INDEX idx_stock_movements_product ON stock_movements(product_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_stock_movements_created_at') THEN
    CREATE INDEX idx_stock_movements_created_at ON stock_movements(created_at DESC);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_stock_movements_created_by') THEN
    CREATE INDEX idx_stock_movements_created_by ON stock_movements(created_by);
  END IF;
END $$;

-- Create trigger function if not exists
CREATE OR REPLACE FUNCTION update_warehouse_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger for warehouse_permissions
DROP TRIGGER IF EXISTS update_warehouse_permissions_updated_at ON warehouse_permissions;
CREATE TRIGGER update_warehouse_permissions_updated_at
  BEFORE UPDATE ON warehouse_permissions
  FOR EACH ROW
  EXECUTE FUNCTION update_warehouse_updated_at();