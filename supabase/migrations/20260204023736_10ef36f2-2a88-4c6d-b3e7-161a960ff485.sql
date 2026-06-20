
-- Table pour archiver les utilisateurs supprimés (restauration possible)
CREATE TABLE IF NOT EXISTS public.deleted_users_archive (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  original_user_id UUID NOT NULL,
  email TEXT,
  phone TEXT,
  full_name TEXT,
  role TEXT,
  public_id TEXT,
  
  -- Données du profil complet
  profile_data JSONB,
  
  -- Données associées (wallet, IDs, etc.)
  wallet_data JSONB,
  user_ids_data JSONB,
  role_specific_data JSONB,
  
  -- Métadonnées de suppression
  deleted_by UUID,
  deletion_reason TEXT,
  deletion_method TEXT DEFAULT 'manual',
  
  -- Dates
  original_created_at TIMESTAMPTZ,
  deleted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  
  -- Restauration
  restored_at TIMESTAMPTZ,
  restored_by UUID,
  restoration_notes TEXT,
  is_restored BOOLEAN DEFAULT false,
  
  -- Expiration automatique (RGPD: 30 jours par défaut)
  expires_at TIMESTAMPTZ DEFAULT (now() + interval '30 days'),
  
  -- Index pour recherche rapide
  CONSTRAINT deleted_users_archive_email_check CHECK (email IS NOT NULL OR phone IS NOT NULL)
);

-- Index pour recherche rapide
CREATE INDEX IF NOT EXISTS idx_deleted_users_email ON deleted_users_archive(email);
CREATE INDEX IF NOT EXISTS idx_deleted_users_public_id ON deleted_users_archive(public_id);
CREATE INDEX IF NOT EXISTS idx_deleted_users_deleted_at ON deleted_users_archive(deleted_at DESC);
CREATE INDEX IF NOT EXISTS idx_deleted_users_not_restored ON deleted_users_archive(is_restored) WHERE is_restored = false;

-- RLS
ALTER TABLE deleted_users_archive ENABLE ROW LEVEL SECURITY;

-- Seuls les admins/PDG peuvent voir et restaurer
CREATE POLICY "Only admins can view deleted users archive"
  ON deleted_users_archive FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM profiles 
      WHERE profiles.id = auth.uid() 
      AND profiles.role IN ('admin', 'pdg', 'ceo')
    )
  );

CREATE POLICY "Only admins can insert to deleted users archive"
  ON deleted_users_archive FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM profiles 
      WHERE profiles.id = auth.uid() 
      AND profiles.role IN ('admin', 'pdg', 'ceo')
    )
  );

CREATE POLICY "Only admins can update deleted users archive"
  ON deleted_users_archive FOR UPDATE
  USING (
    EXISTS (
      SELECT 1 FROM profiles 
      WHERE profiles.id = auth.uid() 
      AND profiles.role IN ('admin', 'pdg', 'ceo')
    )
  );

-- Fonction pour archiver automatiquement un utilisateur avant suppression
CREATE OR REPLACE FUNCTION archive_user_before_deletion(
  p_user_id UUID,
  p_deleted_by UUID DEFAULT NULL,
  p_reason TEXT DEFAULT 'Suppression manuelle'
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_archive_id UUID;
  v_profile RECORD;
  v_wallet RECORD;
  v_user_ids RECORD;
BEGIN
  -- Récupérer le profil
  SELECT * INTO v_profile FROM profiles WHERE id = p_user_id;
  
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Utilisateur non trouvé: %', p_user_id;
  END IF;
  
  -- Récupérer le wallet
  SELECT * INTO v_wallet FROM wallets WHERE user_id = p_user_id;
  
  -- Récupérer les IDs
  SELECT * INTO v_user_ids FROM user_ids WHERE user_id = p_user_id;
  
  -- Insérer dans l'archive
  INSERT INTO deleted_users_archive (
    original_user_id,
    email,
    phone,
    full_name,
    role,
    public_id,
    profile_data,
    wallet_data,
    user_ids_data,
    deleted_by,
    deletion_reason,
    original_created_at
  ) VALUES (
    p_user_id,
    v_profile.email,
    v_profile.phone,
    v_profile.full_name,
    v_profile.role,
    v_profile.public_id,
    to_jsonb(v_profile),
    CASE WHEN v_wallet IS NOT NULL THEN to_jsonb(v_wallet) ELSE NULL END,
    CASE WHEN v_user_ids IS NOT NULL THEN to_jsonb(v_user_ids) ELSE NULL END,
    p_deleted_by,
    p_reason,
    v_profile.created_at
  )
  RETURNING id INTO v_archive_id;
  
  RETURN v_archive_id;
END;
$$;

-- Commentaires
COMMENT ON TABLE deleted_users_archive IS 'Archive des utilisateurs supprimés pour restauration possible (30 jours)';
COMMENT ON FUNCTION archive_user_before_deletion IS 'Archive un utilisateur avant sa suppression définitive';
