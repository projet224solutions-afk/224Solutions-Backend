-- ============================================
-- MIGRATION MFA - 224SOLUTIONS
-- Tables pour le système MFA personnalisé
-- ============================================

-- Table des facteurs MFA personnalisés (SMS, Email)
CREATE TABLE IF NOT EXISTS public.mfa_factors (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    method TEXT NOT NULL CHECK (method IN ('sms', 'email', 'webauthn')),
    friendly_name TEXT NOT NULL DEFAULT '',
    phone_number TEXT,
    email TEXT,
    verified BOOLEAN NOT NULL DEFAULT false,
    is_primary BOOLEAN NOT NULL DEFAULT false,
    webauthn_credential_id TEXT,
    webauthn_public_key TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_used_at TIMESTAMPTZ,
    
    -- Contraintes
    CONSTRAINT phone_or_email_required CHECK (
        (method = 'sms' AND phone_number IS NOT NULL) OR
        (method = 'email' AND email IS NOT NULL) OR
        (method = 'webauthn' AND webauthn_credential_id IS NOT NULL)
    )
);

-- Index pour les recherches rapides
CREATE INDEX IF NOT EXISTS idx_mfa_factors_user_id ON public.mfa_factors(user_id);
CREATE INDEX IF NOT EXISTS idx_mfa_factors_method ON public.mfa_factors(method);

-- Table des challenges MFA (codes temporaires)
CREATE TABLE IF NOT EXISTS public.mfa_challenges (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    factor_id UUID NOT NULL REFERENCES public.mfa_factors(id) ON DELETE CASCADE,
    code TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    verified_at TIMESTAMPTZ,
    ip_address INET,
    user_agent TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index pour les recherches de codes
CREATE INDEX IF NOT EXISTS idx_mfa_challenges_factor_id ON public.mfa_challenges(factor_id);
CREATE INDEX IF NOT EXISTS idx_mfa_challenges_expires_at ON public.mfa_challenges(expires_at);

-- Table des codes de backup
CREATE TABLE IF NOT EXISTS public.mfa_backup_codes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    factor_id UUID REFERENCES public.mfa_factors(id) ON DELETE CASCADE,
    code TEXT NOT NULL,
    used BOOLEAN NOT NULL DEFAULT false,
    used_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index pour les codes de backup
CREATE INDEX IF NOT EXISTS idx_mfa_backup_codes_user_id ON public.mfa_backup_codes(user_id);
CREATE INDEX IF NOT EXISTS idx_mfa_backup_codes_code ON public.mfa_backup_codes(code);

-- Table de configuration MFA par utilisateur
CREATE TABLE IF NOT EXISTS public.mfa_settings (
    user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    mfa_required BOOLEAN NOT NULL DEFAULT false,
    grace_period_ends TIMESTAMPTZ,
    require_mfa_for TEXT[] DEFAULT ARRAY['login', 'payment', 'settings'],
    trusted_devices JSONB DEFAULT '[]'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Table des logs d'authentification MFA
CREATE TABLE IF NOT EXISTS public.mfa_audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    factor_id UUID REFERENCES public.mfa_factors(id) ON DELETE SET NULL,
    action TEXT NOT NULL CHECK (action IN (
        'factor_enrolled', 
        'factor_verified', 
        'factor_removed',
        'challenge_created',
        'challenge_verified',
        'challenge_failed',
        'backup_code_used',
        'backup_codes_regenerated'
    )),
    ip_address INET,
    user_agent TEXT,
    metadata JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index pour les logs d'audit
CREATE INDEX IF NOT EXISTS idx_mfa_audit_logs_user_id ON public.mfa_audit_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_mfa_audit_logs_created_at ON public.mfa_audit_logs(created_at DESC);

-- ============================================
-- ROW LEVEL SECURITY (RLS)
-- ============================================

-- Activer RLS sur toutes les tables
ALTER TABLE public.mfa_factors ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mfa_challenges ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mfa_backup_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mfa_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mfa_audit_logs ENABLE ROW LEVEL SECURITY;

-- Policies pour mfa_factors
CREATE POLICY "Users can view their own MFA factors"
    ON public.mfa_factors FOR SELECT
    USING (auth.uid() = user_id);

CREATE POLICY "Users can insert their own MFA factors"
    ON public.mfa_factors FOR INSERT
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update their own MFA factors"
    ON public.mfa_factors FOR UPDATE
    USING (auth.uid() = user_id);

CREATE POLICY "Users can delete their own MFA factors"
    ON public.mfa_factors FOR DELETE
    USING (auth.uid() = user_id);

-- Policies pour mfa_challenges
CREATE POLICY "Users can view challenges for their factors"
    ON public.mfa_challenges FOR SELECT
    USING (
        factor_id IN (
            SELECT id FROM public.mfa_factors WHERE user_id = auth.uid()
        )
    );

CREATE POLICY "Users can create challenges for their factors"
    ON public.mfa_challenges FOR INSERT
    WITH CHECK (
        factor_id IN (
            SELECT id FROM public.mfa_factors WHERE user_id = auth.uid()
        )
    );

-- Policies pour mfa_backup_codes
CREATE POLICY "Users can view their own backup codes"
    ON public.mfa_backup_codes FOR SELECT
    USING (auth.uid() = user_id);

CREATE POLICY "Users can manage their own backup codes"
    ON public.mfa_backup_codes FOR ALL
    USING (auth.uid() = user_id);

-- Policies pour mfa_settings
CREATE POLICY "Users can view their own MFA settings"
    ON public.mfa_settings FOR SELECT
    USING (auth.uid() = user_id);

CREATE POLICY "Users can update their own MFA settings"
    ON public.mfa_settings FOR ALL
    USING (auth.uid() = user_id);

-- Policies pour mfa_audit_logs (lecture seule pour l'utilisateur)
CREATE POLICY "Users can view their own MFA logs"
    ON public.mfa_audit_logs FOR SELECT
    USING (auth.uid() = user_id);

-- ============================================
-- FUNCTIONS & TRIGGERS
-- ============================================

-- Fonction pour logger les actions MFA
CREATE OR REPLACE FUNCTION log_mfa_action(
    p_user_id UUID,
    p_factor_id UUID,
    p_action TEXT,
    p_metadata JSONB DEFAULT '{}'::jsonb
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_log_id UUID;
BEGIN
    INSERT INTO public.mfa_audit_logs (
        user_id,
        factor_id,
        action,
        metadata
    ) VALUES (
        p_user_id,
        p_factor_id,
        p_action,
        p_metadata
    ) RETURNING id INTO v_log_id;
    
    RETURN v_log_id;
END;
$$;

-- Trigger pour mettre à jour updated_at
CREATE OR REPLACE FUNCTION update_mfa_settings_timestamp()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trigger_update_mfa_settings_timestamp
    BEFORE UPDATE ON public.mfa_settings
    FOR EACH ROW
    EXECUTE FUNCTION update_mfa_settings_timestamp();

-- Trigger pour s'assurer qu'un seul facteur est principal
CREATE OR REPLACE FUNCTION ensure_single_primary_factor()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.is_primary = true THEN
        UPDATE public.mfa_factors
        SET is_primary = false
        WHERE user_id = NEW.user_id AND id != NEW.id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trigger_ensure_single_primary_factor
    BEFORE INSERT OR UPDATE ON public.mfa_factors
    FOR EACH ROW
    WHEN (NEW.is_primary = true)
    EXECUTE FUNCTION ensure_single_primary_factor();

-- Fonction pour nettoyer les challenges expirés
CREATE OR REPLACE FUNCTION cleanup_expired_mfa_challenges()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_deleted INTEGER;
BEGIN
    DELETE FROM public.mfa_challenges
    WHERE expires_at < NOW()
    RETURNING 1 INTO v_deleted;
    
    RETURN COALESCE(v_deleted, 0);
END;
$$;

-- ============================================
-- CRON JOB (si pg_cron est disponible)
-- ============================================

-- Nettoyer les challenges expirés toutes les heures
-- SELECT cron.schedule('cleanup-mfa-challenges', '0 * * * *', 'SELECT cleanup_expired_mfa_challenges();');

-- ============================================
-- COMMENTAIRES
-- ============================================

COMMENT ON TABLE public.mfa_factors IS 'Facteurs MFA personnalisés (SMS, Email, WebAuthn) - TOTP est géré par Supabase Auth';
COMMENT ON TABLE public.mfa_challenges IS 'Codes de vérification temporaires pour SMS/Email';
COMMENT ON TABLE public.mfa_backup_codes IS 'Codes de récupération MFA';
COMMENT ON TABLE public.mfa_settings IS 'Paramètres MFA par utilisateur';
COMMENT ON TABLE public.mfa_audit_logs IS 'Logs d''audit des actions MFA';
