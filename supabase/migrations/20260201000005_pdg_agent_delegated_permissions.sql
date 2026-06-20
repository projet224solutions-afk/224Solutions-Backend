-- ============================================
-- SYSTÈME DE PERMISSIONS PDG DÉLÉGUÉES AUX AGENTS
-- Permet au PDG de déléguer des tâches spécifiques aux agents
-- ============================================

-- ============================================
-- 1. TABLE DE GESTION DES PERMISSIONS DÉLÉGUÉES
-- ============================================

CREATE TABLE IF NOT EXISTS public.pdg_access_permissions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    pdg_id UUID REFERENCES public.pdg_management(id) ON DELETE CASCADE NOT NULL,
    agent_id UUID REFERENCES public.agents_management(id) ON DELETE CASCADE NOT NULL,
    permission_key TEXT NOT NULL,
    permission_name TEXT NOT NULL,
    description TEXT,
    permission_scope JSONB DEFAULT '{}', -- ex: {"vendor_ids": ["id1", "id2"]} pour limiter à certains vendeurs
    is_active BOOLEAN DEFAULT true,
    delegated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    delegated_by UUID REFERENCES auth.users(id),
    expires_at TIMESTAMP WITH TIME ZONE, -- NULL = sans expiration
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(pdg_id, agent_id, permission_key)
);

-- Index pour performances
CREATE INDEX IF NOT EXISTS idx_pdg_permissions_pdg_id ON public.pdg_access_permissions(pdg_id);
CREATE INDEX IF NOT EXISTS idx_pdg_permissions_agent_id ON public.pdg_access_permissions(agent_id);
CREATE INDEX IF NOT EXISTS idx_pdg_permissions_active ON public.pdg_access_permissions(is_active);

-- ============================================
-- 2. TABLE D'AUDIT DES PERMISSIONS PDG
-- ============================================

CREATE TABLE IF NOT EXISTS public.pdg_permissions_audit (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    pdg_id UUID REFERENCES public.pdg_management(id) ON DELETE CASCADE,
    agent_id UUID REFERENCES public.agents_management(id) ON DELETE CASCADE,
    action TEXT NOT NULL, -- 'grant', 'revoke', 'modify', 'expire'
    permission_key TEXT NOT NULL,
    old_value JSONB,
    new_value JSONB,
    reason TEXT,
    executed_by UUID REFERENCES auth.users(id),
    executed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    ip_address TEXT,
    user_agent TEXT
);

CREATE INDEX IF NOT EXISTS idx_permissions_audit_pdg_id ON public.pdg_permissions_audit(pdg_id);
CREATE INDEX IF NOT EXISTS idx_permissions_audit_agent_id ON public.pdg_permissions_audit(agent_id);

-- ============================================
-- 3. ÉNUMÉRATION DES PERMISSIONS PDG DISPONIBLES
-- ============================================

CREATE TABLE IF NOT EXISTS public.pdg_permission_catalog (
    permission_key TEXT PRIMARY KEY,
    permission_name TEXT NOT NULL,
    description TEXT,
    category TEXT NOT NULL, -- 'users', 'finance', 'analytics', 'operations', 'security', 'system'
    risk_level TEXT NOT NULL CHECK (risk_level IN ('low', 'medium', 'high', 'critical')),
    requires_2fa BOOLEAN DEFAULT false,
    requires_audit BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Insérer le catalogue de permissions PDG
INSERT INTO public.pdg_permission_catalog 
    (permission_key, permission_name, description, category, risk_level, requires_2fa, requires_audit) 
VALUES
    -- Gestion des utilisateurs
    ('pdg_manage_vendors', 'Gestion des vendeurs', 'Créer, modifier, supprimer les vendeurs', 'users', 'high', true, true),
    ('pdg_manage_drivers', 'Gestion des chauffeurs', 'Gérer les chauffeurs et taxis', 'users', 'medium', false, true),
    ('pdg_manage_users', 'Gestion des utilisateurs', 'Créer, modifier, supprimer les utilisateurs', 'users', 'critical', true, true),
    ('pdg_ban_unban_users', 'Bannissement/débannissement', 'Bannir ou débannir des utilisateurs', 'users', 'high', true, true),
    ('pdg_verify_kyc', 'Vérification KYC', 'Approuver/rejeter la vérification KYC', 'users', 'high', true, true),
    
    -- Finance et paiements
    ('pdg_access_wallet', 'Accès au portefeuille PDG', 'Accéder au portefeuille principal', 'finance', 'critical', true, true),
    ('pdg_manage_commissions', 'Gestion des commissions', 'Configurer et modifier les commissions', 'finance', 'high', true, true),
    ('pdg_manage_escrow', 'Gestion du séquestre', 'Gérer les transactions en séquestre', 'finance', 'high', true, true),
    ('pdg_refund_transactions', 'Remboursements', 'Effectuer des remboursements', 'finance', 'critical', true, true),
    ('pdg_view_financial_dashboard', 'Tableau de bord financier', 'Voir les statistiques financières', 'finance', 'medium', false, false),
    ('pdg_manage_payment_methods', 'Méthodes de paiement', 'Gérer les méthodes de paiement', 'finance', 'high', true, true),
    
    -- Analytics et rapports
    ('pdg_view_analytics', 'Accès aux analytiques', 'Voir les statistiques et analytiques', 'analytics', 'low', false, false),
    ('pdg_view_reports', 'Rapports système', 'Accéder aux rapports détaillés', 'analytics', 'medium', false, false),
    ('pdg_export_data', 'Export de données', 'Exporter les données système', 'analytics', 'medium', false, true),
    
    -- Opérations
    ('pdg_manage_orders', 'Gestion des commandes', 'Modifier ou annuler les commandes', 'operations', 'high', true, true),
    ('pdg_manage_deliveries', 'Gestion des livraisons', 'Modifier les livraisons', 'operations', 'medium', false, true),
    ('pdg_manage_subscriptions', 'Gestion des abonnements', 'Créer/modifier les abonnements', 'operations', 'medium', false, true),
    ('pdg_manage_inventory', 'Gestion de l''inventaire', 'Modifier les stocks', 'operations', 'medium', false, true),
    
    -- Sécurité et système
    ('pdg_view_security_logs', 'Logs de sécurité', 'Accéder aux journaux de sécurité', 'security', 'high', false, true),
    ('pdg_manage_api_keys', 'Gestion des clés API', 'Créer/révoquer les clés API', 'security', 'critical', true, true),
    ('pdg_manage_system_config', 'Configuration système', 'Modifier la configuration système', 'system', 'critical', true, true),
    ('pdg_manage_agents', 'Gestion des agents', 'Créer et gérer les agents', 'system', 'high', true, true),
    ('pdg_view_system_logs', 'Logs système', 'Accéder aux logs système', 'system', 'high', false, true),
    ('pdg_manage_roles', 'Gestion des rôles', 'Modifier les rôles et permissions', 'security', 'critical', true, true),
    
    -- Modules spécialisés
    ('pdg_manage_syndicate', 'Gestion syndicats', 'Gérer les syndicats', 'operations', 'medium', false, true),
    ('pdg_manage_suppliers', 'Gestion fournisseurs', 'Gérer les fournisseurs', 'operations', 'medium', false, true),
    ('pdg_manage_disputes', 'Gestion des litiges', 'Résoudre les litiges', 'operations', 'high', true, true),
    ('pdg_id_normalization', 'Normalisation d''ID', 'Corriger les IDs d''utilisateurs', 'system', 'high', true, true)
ON CONFLICT (permission_key) DO NOTHING;

-- ============================================
-- 4. FONCTIONS POUR ACCORDER/RÉVOQUER PERMISSIONS
-- ============================================

-- Fonction pour accorder une permission à un agent
CREATE OR REPLACE FUNCTION public.grant_pdg_permission_to_agent(
    p_pdg_id UUID,
    p_agent_id UUID,
    p_permission_key TEXT,
    p_scope JSONB DEFAULT NULL,
    p_expires_in_days INT DEFAULT NULL
)
RETURNS TABLE(success BOOLEAN, message TEXT, permission_id UUID)
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
    v_permission_id UUID;
    v_permission_exists BOOLEAN;
    v_expires_at TIMESTAMP WITH TIME ZONE;
BEGIN
    -- Vérifier que la permission existe
    SELECT EXISTS(SELECT 1 FROM pdg_permission_catalog WHERE permission_key = p_permission_key)
    INTO v_permission_exists;

    IF NOT v_permission_exists THEN
        RETURN QUERY SELECT false, 'Permission inexistante: ' || p_permission_key, NULL::UUID;
        RETURN;
    END IF;

    -- Calculer la date d'expiration
    v_expires_at := CASE 
        WHEN p_expires_in_days IS NOT NULL THEN NOW() + (p_expires_in_days || ' days')::INTERVAL
        ELSE NULL
    END;

    -- Insérer ou mettre à jour la permission
    INSERT INTO public.pdg_access_permissions
        (pdg_id, agent_id, permission_key, permission_name, permission_scope, expires_at, delegated_by)
    SELECT 
        p_pdg_id,
        p_agent_id,
        p_permission_key,
        permission_name,
        p_scope,
        v_expires_at,
        auth.uid()
    FROM pdg_permission_catalog
    WHERE permission_key = p_permission_key
    ON CONFLICT (pdg_id, agent_id, permission_key) DO UPDATE SET
        is_active = true,
        permission_scope = COALESCE(p_scope, pdg_access_permissions.permission_scope),
        expires_at = v_expires_at,
        updated_at = NOW()
    RETURNING id INTO v_permission_id;

    -- Audit
    INSERT INTO public.pdg_permissions_audit
        (pdg_id, agent_id, action, permission_key, new_value, executed_by, reason)
    VALUES
        (p_pdg_id, p_agent_id, 'grant', p_permission_key, to_jsonb(p_scope), auth.uid(), 'Via grant_pdg_permission_to_agent');

    RETURN QUERY SELECT true, 'Permission accordée avec succès', v_permission_id;
END;
$$;

-- Fonction pour révoquer une permission
CREATE OR REPLACE FUNCTION public.revoke_pdg_permission_from_agent(
    p_pdg_id UUID,
    p_agent_id UUID,
    p_permission_key TEXT,
    p_reason TEXT DEFAULT NULL
)
RETURNS TABLE(success BOOLEAN, message TEXT)
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE public.pdg_access_permissions
    SET is_active = false, updated_at = NOW()
    WHERE pdg_id = p_pdg_id AND agent_id = p_agent_id AND permission_key = p_permission_key;

    -- Audit
    INSERT INTO public.pdg_permissions_audit
        (pdg_id, agent_id, action, permission_key, executed_by, reason)
    VALUES
        (p_pdg_id, p_agent_id, 'revoke', p_permission_key, auth.uid(), p_reason);

    RETURN QUERY SELECT true, 'Permission révoquée avec succès';
END;
$$;

-- Fonction pour vérifier si un agent a une permission
CREATE OR REPLACE FUNCTION public.agent_has_permission(
    p_agent_id UUID,
    p_permission_key TEXT
)
RETURNS BOOLEAN
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
    v_has_permission BOOLEAN;
BEGIN
    SELECT EXISTS(
        SELECT 1 FROM public.pdg_access_permissions
        WHERE agent_id = p_agent_id
        AND permission_key = p_permission_key
        AND is_active = true
        AND (expires_at IS NULL OR expires_at > NOW())
    ) INTO v_has_permission;

    RETURN v_has_permission;
END;
$$;

-- ============================================
-- 5. POLITIQUES RLS
-- ============================================

-- Politique: PDG peut voir et gérer ses permissions déléguées
CREATE POLICY "PDG can view own delegated permissions"
ON public.pdg_access_permissions
FOR SELECT
USING (
    pdg_id = auth.uid() 
    OR 
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'pdg'))
);

CREATE POLICY "PDG can manage delegated permissions"
ON public.pdg_access_permissions
FOR ALL
USING (
    pdg_id IN (SELECT id FROM pdg_management WHERE user_id = auth.uid())
)
WITH CHECK (
    pdg_id IN (SELECT id FROM pdg_management WHERE user_id = auth.uid())
);

-- Politique: Agents peuvent voir leurs permissions déléguées
CREATE POLICY "Agents can view own permissions"
ON public.pdg_access_permissions
FOR SELECT
USING (
    agent_id IN (SELECT id FROM agents_management WHERE user_id = auth.uid())
    AND is_active = true
    AND (expires_at IS NULL OR expires_at > NOW())
);

-- Politique: Audit logs accessibles aux PDG
CREATE POLICY "PDG can view audit logs"
ON public.pdg_permissions_audit
FOR SELECT
USING (
    pdg_id IN (SELECT id FROM pdg_management WHERE user_id = auth.uid())
);

-- Politique: Catalogue de permissions accessible à tous les authentifiés
CREATE POLICY "Authenticated can view permission catalog"
ON public.pdg_permission_catalog
FOR SELECT
USING (true);

-- ============================================
-- 6. COMMENTAIRES ET DOCUMENTATION
-- ============================================

COMMENT ON TABLE public.pdg_access_permissions IS 'Gère les permissions déléguées du PDG aux agents';
COMMENT ON TABLE public.pdg_permissions_audit IS 'Audit trail des modifications de permissions';
COMMENT ON TABLE public.pdg_permission_catalog IS 'Catalogue des permissions PDG disponibles';

COMMENT ON FUNCTION grant_pdg_permission_to_agent IS 'Accorde une permission PDG à un agent';
COMMENT ON FUNCTION revoke_pdg_permission_from_agent IS 'Révoque une permission PDG d''un agent';
COMMENT ON FUNCTION agent_has_permission IS 'Vérifie si un agent a une permission active';
