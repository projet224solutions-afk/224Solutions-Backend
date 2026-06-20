-- Drop old constraint
ALTER TABLE vehicle_fraud_alerts DROP CONSTRAINT IF EXISTS vehicle_fraud_alerts_alert_type_check;

-- Add comprehensive alert type constraint with all possible types
ALTER TABLE vehicle_fraud_alerts ADD CONSTRAINT vehicle_fraud_alerts_alert_type_check 
CHECK (alert_type = ANY (ARRAY[
  'REACTIVATION_ATTEMPT'::text, 
  'DEVICE_MISMATCH'::text, 
  'GPS_ANOMALY'::text, 
  'API_ABUSE'::text, 
  'PAYMENT_ATTEMPT'::text, 
  'TRIP_REQUEST'::text, 
  'DATA_MODIFICATION'::text,
  'STOLEN_DECLARATION'::text,
  'STOLEN_RECOVERY'::text,
  'USAGE_ATTEMPT'::text,
  'LOCATION_UPDATE'::text,
  'UNAUTHORIZED_ACCESS'::text,
  'SUSPICIOUS_ACTIVITY'::text
]));