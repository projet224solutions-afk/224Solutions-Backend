-- Corriger les policies RLS sur sos_alerts pour restreindre l'accès public
-- Supprimer les policies trop permissives
DROP POLICY IF EXISTS "Public SOS access" ON sos_alerts;
DROP POLICY IF EXISTS "sos_alerts_public_read" ON sos_alerts;
DROP POLICY IF EXISTS "Anyone can read sos_alerts" ON sos_alerts;
DROP POLICY IF EXISTS "authorized_sos_access" ON sos_alerts;
DROP POLICY IF EXISTS "service_role_all" ON sos_alerts;

-- Créer une nouvelle policy restrictive pour sos_alerts
CREATE POLICY "authorized_sos_access" ON sos_alerts
FOR SELECT USING (
  -- Le chauffeur peut voir ses alertes
  auth.uid() = taxi_driver_id 
  OR 
  -- Les rôles autorisés peuvent tout voir (admin, ceo, syndicat)
  EXISTS (
    SELECT 1 FROM profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role IN ('ceo', 'admin', 'syndicat')
  )
);

-- Créer policy pour INSERT (chauffeurs taxi et livreurs)
DROP POLICY IF EXISTS "Users can insert their sos_alerts" ON sos_alerts;
DROP POLICY IF EXISTS "users_create_own_sos" ON sos_alerts;
CREATE POLICY "drivers_create_own_sos" ON sos_alerts
FOR INSERT WITH CHECK (
  auth.uid() = taxi_driver_id 
  OR 
  EXISTS (
    SELECT 1 FROM profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role IN ('taxi', 'livreur')
  )
);

-- Créer policy pour UPDATE (propriétaire ou admin)
DROP POLICY IF EXISTS "Users can update their sos_alerts" ON sos_alerts;
DROP POLICY IF EXISTS "authorized_sos_update" ON sos_alerts;
CREATE POLICY "authorized_sos_update" ON sos_alerts
FOR UPDATE USING (
  auth.uid() = taxi_driver_id 
  OR 
  EXISTS (
    SELECT 1 FROM profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role IN ('ceo', 'admin', 'syndicat')
  )
);

-- Policy service_role pour les opérations backend
CREATE POLICY "service_role_sos_access" ON sos_alerts
FOR ALL TO service_role USING (true) WITH CHECK (true);

-- Corriger les policies sur sos_media également
DROP POLICY IF EXISTS "Public SOS media access" ON sos_media;
DROP POLICY IF EXISTS "sos_media_public_read" ON sos_media;
DROP POLICY IF EXISTS "authorized_sos_media_access" ON sos_media;
DROP POLICY IF EXISTS "users_create_own_sos_media" ON sos_media;
DROP POLICY IF EXISTS "service_role_all" ON sos_media;

CREATE POLICY "authorized_sos_media_access" ON sos_media
FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM sos_alerts sa
    WHERE sa.id = sos_media.sos_alert_id
    AND (
      sa.taxi_driver_id = auth.uid()
      OR EXISTS (
        SELECT 1 FROM profiles
        WHERE profiles.id = auth.uid()
        AND profiles.role IN ('ceo', 'admin', 'syndicat')
      )
    )
  )
);

-- Policy pour INSERT sur sos_media
CREATE POLICY "drivers_create_own_sos_media" ON sos_media
FOR INSERT WITH CHECK (
  EXISTS (
    SELECT 1 FROM sos_alerts sa
    WHERE sa.id = sos_media.sos_alert_id
    AND sa.taxi_driver_id = auth.uid()
  )
);

-- Policy service_role pour sos_media
CREATE POLICY "service_role_sos_media" ON sos_media
FOR ALL TO service_role USING (true) WITH CHECK (true);