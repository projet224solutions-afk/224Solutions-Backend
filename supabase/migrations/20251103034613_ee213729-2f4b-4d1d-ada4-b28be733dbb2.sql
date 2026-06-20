-- Politiques RLS pour les tables de sécurité (accès admin uniquement)

-- Security Incidents
DROP POLICY IF EXISTS "Admins can read security incidents" ON public.security_incidents;
CREATE POLICY "Admins can read security incidents"
ON public.security_incidents
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'
  )
);

DROP POLICY IF EXISTS "Admins can insert security incidents" ON public.security_incidents;
CREATE POLICY "Admins can insert security incidents"
ON public.security_incidents
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'
  )
);

DROP POLICY IF EXISTS "Admins can update security incidents" ON public.security_incidents;
CREATE POLICY "Admins can update security incidents"
ON public.security_incidents
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'
  )
);

-- Security Alerts
DROP POLICY IF EXISTS "Admins can read security alerts" ON public.security_alerts;
CREATE POLICY "Admins can read security alerts"
ON public.security_alerts
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'
  )
);

DROP POLICY IF EXISTS "Admins can insert security alerts" ON public.security_alerts;
CREATE POLICY "Admins can insert security alerts"
ON public.security_alerts
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'
  )
);

DROP POLICY IF EXISTS "Admins can update security alerts" ON public.security_alerts;
CREATE POLICY "Admins can update security alerts"
ON public.security_alerts
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'
  )
);

-- Blocked IPs
DROP POLICY IF EXISTS "Admins can read blocked ips" ON public.blocked_ips;
CREATE POLICY "Admins can read blocked ips"
ON public.blocked_ips
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'
  )
);

DROP POLICY IF EXISTS "Admins can insert blocked ips" ON public.blocked_ips;
CREATE POLICY "Admins can insert blocked ips"
ON public.blocked_ips
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'
  )
);

DROP POLICY IF EXISTS "Admins can update blocked ips" ON public.blocked_ips;
CREATE POLICY "Admins can update blocked ips"
ON public.blocked_ips
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'
  )
);

DROP POLICY IF EXISTS "Admins can delete blocked ips" ON public.blocked_ips;
CREATE POLICY "Admins can delete blocked ips"
ON public.blocked_ips
FOR DELETE
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'
  )
);