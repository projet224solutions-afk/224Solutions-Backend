-- Supprimer les politiques dupliquées et recréer proprement
DROP POLICY IF EXISTS "Authenticated users can view all SOS alerts" ON sos_alerts;
DROP POLICY IF EXISTS "Authenticated users can create SOS alerts" ON sos_alerts;
DROP POLICY IF EXISTS "Authenticated users can update SOS alerts" ON sos_alerts;

-- Recréer les politiques correctes
CREATE POLICY "Authenticated users can view all SOS alerts"
ON sos_alerts FOR SELECT TO authenticated USING (true);

CREATE POLICY "Authenticated users can create SOS alerts"
ON sos_alerts FOR INSERT TO authenticated WITH CHECK (true);

CREATE POLICY "Authenticated users can update SOS alerts"
ON sos_alerts FOR UPDATE TO authenticated USING (true);