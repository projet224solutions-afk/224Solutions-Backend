-- Add missing bureau_id column to vehicle_fraud_alerts
ALTER TABLE vehicle_fraud_alerts ADD COLUMN IF NOT EXISTS bureau_id UUID REFERENCES bureaus(id);

-- Create index for performance
CREATE INDEX IF NOT EXISTS idx_vehicle_fraud_alerts_bureau_id ON vehicle_fraud_alerts(bureau_id);