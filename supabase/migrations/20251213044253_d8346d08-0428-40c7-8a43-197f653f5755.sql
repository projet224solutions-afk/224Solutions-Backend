-- Recréer les politiques RLS avec les rôles corrects (admin, ceo)

-- 1. Supprimer les anciennes politiques si elles existent
DROP POLICY IF EXISTS "Bureau peut voir logs de ses véhicules" ON vehicle_security_log;
DROP POLICY IF EXISTS "Bureau peut voir alertes de ses véhicules" ON vehicle_fraud_alerts;
DROP POLICY IF EXISTS "Bureau peut voir GPS de ses véhicules volés" ON vehicle_gps_tracking;
DROP POLICY IF EXISTS "Bureau et PDG peuvent voir logs" ON vehicle_security_log;
DROP POLICY IF EXISTS "Bureau et PDG peuvent voir alertes" ON vehicle_fraud_alerts;
DROP POLICY IF EXISTS "Bureau et PDG peuvent voir GPS" ON vehicle_gps_tracking;

-- 2. Recréer les politiques avec les bons rôles

-- Journal de sécurité
CREATE POLICY "Accès logs sécurité véhicules"
ON vehicle_security_log FOR SELECT
USING (
    bureau_id IN (
        SELECT id FROM bureaus WHERE access_token IS NOT NULL
    )
    OR EXISTS (
        SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'ceo')
    )
);

-- Alertes fraude
CREATE POLICY "Accès alertes fraude véhicules"
ON vehicle_fraud_alerts FOR SELECT
USING (
    vehicle_id IN (
        SELECT v.id FROM vehicles v WHERE v.bureau_id IN (
            SELECT id FROM bureaus WHERE access_token IS NOT NULL
        )
    )
    OR EXISTS (
        SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'ceo')
    )
);

-- GPS Tracking
CREATE POLICY "Accès GPS véhicules volés"
ON vehicle_gps_tracking FOR SELECT
USING (
    (
        vehicle_id IN (
            SELECT v.id FROM vehicles v 
            WHERE v.bureau_id IN (SELECT id FROM bureaus WHERE access_token IS NOT NULL)
            AND v.stolen_status = 'stolen'
        )
    )
    OR EXISTS (
        SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'ceo')
    )
);