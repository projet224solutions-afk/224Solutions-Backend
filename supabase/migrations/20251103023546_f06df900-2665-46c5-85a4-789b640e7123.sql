-- Table pour stocker les erreurs système et les correctifs
CREATE TABLE IF NOT EXISTS public.system_errors (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  module VARCHAR(100) NOT NULL,
  error_type VARCHAR(100),
  error_message TEXT NOT NULL,
  stack_trace TEXT,
  fix_applied BOOLEAN DEFAULT false,
  fix_description TEXT,
  severity VARCHAR(50) CHECK (severity IN ('critique', 'modérée', 'mineure')) DEFAULT 'mineure',
  status VARCHAR(50) CHECK (status IN ('detected', 'fixing', 'fixed', 'failed')) DEFAULT 'detected',
  user_id UUID REFERENCES auth.users(id),
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  fixed_at TIMESTAMP WITH TIME ZONE,
  admin_notified BOOLEAN DEFAULT false,
  admin_acknowledged_at TIMESTAMP WITH TIME ZONE
);

-- Index pour recherche rapide
CREATE INDEX idx_system_errors_severity ON public.system_errors(severity);
CREATE INDEX idx_system_errors_status ON public.system_errors(status);
CREATE INDEX idx_system_errors_created_at ON public.system_errors(created_at DESC);
CREATE INDEX idx_system_errors_module ON public.system_errors(module);

-- RLS pour la table system_errors
ALTER TABLE public.system_errors ENABLE ROW LEVEL SECURITY;

-- Les utilisateurs authentifiés peuvent insérer des erreurs
CREATE POLICY "authenticated_can_insert_errors"
  ON public.system_errors
  FOR INSERT
  TO authenticated
  WITH CHECK (true);

-- Les admins peuvent voir toutes les erreurs
CREATE POLICY "admin_can_view_all_errors"
  ON public.system_errors
  FOR SELECT
  TO authenticated
  USING (has_role(auth.uid(), 'admin'::user_role));

-- Les admins peuvent mettre à jour les erreurs
CREATE POLICY "admin_can_update_errors"
  ON public.system_errors
  FOR UPDATE
  TO authenticated
  USING (has_role(auth.uid(), 'admin'::user_role))
  WITH CHECK (has_role(auth.uid(), 'admin'::user_role));

-- Table pour stocker les statistiques du système
CREATE TABLE IF NOT EXISTS public.system_health (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  cpu_usage DECIMAL(5,2),
  memory_usage DECIMAL(5,2),
  db_connections INTEGER,
  api_response_time INTEGER,
  error_rate DECIMAL(5,2),
  status VARCHAR(50) CHECK (status IN ('healthy', 'warning', 'critical')) DEFAULT 'healthy',
  metadata JSONB DEFAULT '{}'::jsonb
);

-- Index pour les statistiques
CREATE INDEX idx_system_health_timestamp ON public.system_health(timestamp DESC);
CREATE INDEX idx_system_health_status ON public.system_health(status);

-- RLS pour system_health
ALTER TABLE public.system_health ENABLE ROW LEVEL SECURITY;

-- Les admins peuvent voir les stats
CREATE POLICY "admin_can_view_health"
  ON public.system_health
  FOR SELECT
  TO authenticated
  USING (has_role(auth.uid(), 'admin'::user_role));

-- Service role peut insérer des stats
CREATE POLICY "service_can_insert_health"
  ON public.system_health
  FOR INSERT
  TO authenticated
  WITH CHECK (true);

-- Table pour les correctifs automatiques disponibles
CREATE TABLE IF NOT EXISTS public.auto_fixes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  error_pattern TEXT NOT NULL,
  fix_type VARCHAR(100) NOT NULL,
  fix_code TEXT,
  fix_description TEXT NOT NULL,
  success_rate DECIMAL(5,2) DEFAULT 0,
  times_applied INTEGER DEFAULT 0,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- RLS pour auto_fixes
ALTER TABLE public.auto_fixes ENABLE ROW LEVEL SECURITY;

-- Les admins peuvent gérer les correctifs
CREATE POLICY "admin_can_manage_fixes"
  ON public.auto_fixes
  FOR ALL
  TO authenticated
  USING (has_role(auth.uid(), 'admin'::user_role))
  WITH CHECK (has_role(auth.uid(), 'admin'::user_role));

-- Insérer des correctifs automatiques de base
INSERT INTO public.auto_fixes (error_pattern, fix_type, fix_description, is_active) VALUES
  ('ECONNREFUSED', 'reconnect_db', 'Reconnexion automatique à la base de données', true),
  ('Cannot read property', 'null_check', 'Ajout de vérification de nullité', true),
  ('undefined is not an object', 'undefined_check', 'Vérification de variable undefined', true),
  ('Network request failed', 'retry_request', 'Nouvelle tentative de requête réseau', true),
  ('timeout', 'increase_timeout', 'Augmentation du délai d''attente', true),
  ('violates row-level security', 'rls_check', 'Vérification des politiques RLS', true);

-- Fonction pour nettoyer les anciennes erreurs (>30 jours)
CREATE OR REPLACE FUNCTION clean_old_errors()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  DELETE FROM public.system_errors
  WHERE created_at < NOW() - INTERVAL '30 days'
  AND severity = 'mineure'
  AND fix_applied = true;
END;
$$;