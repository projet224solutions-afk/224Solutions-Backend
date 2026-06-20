-- Supprimer et recréer la contrainte avec tous les types d'alerte nécessaires
ALTER TABLE vehicle_fraud_alerts DROP CONSTRAINT IF EXISTS vehicle_fraud_alerts_alert_type_check;

ALTER TABLE vehicle_fraud_alerts ADD CONSTRAINT vehicle_fraud_alerts_alert_type_check 
CHECK (alert_type = ANY (ARRAY[
    'REACTIVATION_ATTEMPT',
    'DEVICE_MISMATCH',
    'GPS_ANOMALY',
    'API_ABUSE',
    'PAYMENT_ATTEMPT',
    'TRIP_REQUEST',
    'DATA_MODIFICATION',
    'STOLEN_DECLARATION',
    'STOLEN_RECOVERY',
    'USAGE_ATTEMPT',
    'LOCATION_UPDATE',
    'UNAUTHORIZED_ACCESS',
    'SUSPICIOUS_ACTIVITY',
    'THEFT_DECLARATION',
    'BLOCKED_OPERATION_ATTEMPT',
    'RECOVERY_DECLARATION'
]::text[]));