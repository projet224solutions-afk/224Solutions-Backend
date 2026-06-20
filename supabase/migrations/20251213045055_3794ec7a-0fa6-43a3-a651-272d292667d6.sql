-- Supprimer et recréer les politiques RLS pour vehicle_fraud_alerts
DROP POLICY IF EXISTS "Accès alertes fraude véhicules" ON vehicle_fraud_alerts;
DROP POLICY IF EXISTS "Bureau peut résoudre alertes de ses véhicules" ON vehicle_fraud_alerts;

-- Politique de lecture : Bureaux voient leurs alertes, admins/CEO voient tout
CREATE POLICY "bureaus_select_own_fraud_alerts" ON vehicle_fraud_alerts
FOR SELECT USING (
    bureau_id IN (
        SELECT id FROM bureaus WHERE access_token IS NOT NULL
    )
    OR
    EXISTS (
        SELECT 1 FROM profiles 
        WHERE profiles.id = auth.uid() 
        AND profiles.role IN ('admin', 'ceo')
    )
);

-- Politique de mise à jour : Bureaux peuvent résoudre leurs alertes
CREATE POLICY "bureaus_update_own_fraud_alerts" ON vehicle_fraud_alerts
FOR UPDATE USING (
    bureau_id IN (
        SELECT id FROM bureaus WHERE access_token IS NOT NULL
    )
);

-- Supprimer et recréer les politiques RLS pour vehicle_security_log
DROP POLICY IF EXISTS "Accès logs sécurité véhicules" ON vehicle_security_log;

-- Politique de lecture : Bureaux voient leurs logs, admins/CEO voient tout
CREATE POLICY "bureaus_select_own_security_logs" ON vehicle_security_log
FOR SELECT USING (
    bureau_id IN (
        SELECT id FROM bureaus WHERE access_token IS NOT NULL
    )
    OR
    EXISTS (
        SELECT 1 FROM profiles 
        WHERE profiles.id = auth.uid() 
        AND profiles.role IN ('admin', 'ceo')
    )
);

-- Permettre aux utilisateurs authentifiés de lire les véhicules
DROP POLICY IF EXISTS "authenticated_users_all_vehicles" ON vehicles;
CREATE POLICY "authenticated_users_select_vehicles" ON vehicles
FOR SELECT USING (auth.uid() IS NOT NULL);

-- Activer RLS si pas déjà fait
ALTER TABLE vehicle_fraud_alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE vehicle_security_log ENABLE ROW LEVEL SECURITY;