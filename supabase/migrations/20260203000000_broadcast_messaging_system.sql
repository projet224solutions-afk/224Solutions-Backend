-- ============================================
-- MODULE BROADCAST MESSAGING SYSTEM
-- Système de diffusion de messages globaux/ciblés
-- ============================================

-- 1. Table principale des broadcasts
CREATE TABLE IF NOT EXISTS broadcast_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Auteur du message
  sender_id UUID NOT NULL REFERENCES auth.users(id),
  sender_name TEXT,

  -- Contenu du message
  title TEXT NOT NULL,
  content TEXT NOT NULL,
  content_html TEXT, -- Contenu WYSIWYG formaté
  image_url TEXT,
  link_url TEXT,
  link_text TEXT,

  -- Ciblage / Segmentation
  target_segment TEXT NOT NULL DEFAULT 'all' CHECK (target_segment IN (
    'all', 'agents', 'vendors', 'clients', 'drivers', 'admins', 'custom'
  )),
  target_roles TEXT[] DEFAULT '{}', -- Pour segments personnalisés
  target_regions TEXT[] DEFAULT '{}', -- Ciblage géographique
  target_user_ids UUID[] DEFAULT '{}', -- Utilisateurs spécifiques

  -- Priorité et type
  priority TEXT NOT NULL DEFAULT 'normal' CHECK (priority IN ('normal', 'high', 'urgent')),
  message_type TEXT NOT NULL DEFAULT 'announcement' CHECK (message_type IN (
    'announcement', 'promotion', 'alert', 'maintenance', 'update', 'news'
  )),

  -- Planification
  scheduled_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ,

  -- Statut
  status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN (
    'draft', 'scheduled', 'sending', 'sent', 'cancelled', 'expired'
  )),
  sent_at TIMESTAMPTZ,

  -- Métadonnées
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2. Table de suivi des réceptions
CREATE TABLE IF NOT EXISTS broadcast_recipients (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  broadcast_id UUID NOT NULL REFERENCES broadcast_messages(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,

  -- Statut de lecture
  delivered_at TIMESTAMPTZ DEFAULT NOW(),
  read_at TIMESTAMPTZ,
  clicked_at TIMESTAMPTZ, -- Si lien cliqué
  dismissed_at TIMESTAMPTZ,

  -- Canal de réception
  channel TEXT DEFAULT 'internal' CHECK (channel IN ('internal', 'push', 'email', 'sms')),

  UNIQUE(broadcast_id, user_id)
);

-- 3. Table des métriques agrégées
CREATE TABLE IF NOT EXISTS broadcast_metrics (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  broadcast_id UUID NOT NULL REFERENCES broadcast_messages(id) ON DELETE CASCADE UNIQUE,

  -- Compteurs
  total_recipients INTEGER DEFAULT 0,
  total_delivered INTEGER DEFAULT 0,
  total_read INTEGER DEFAULT 0,
  total_clicked INTEGER DEFAULT 0,
  total_dismissed INTEGER DEFAULT 0,

  -- Taux
  delivery_rate NUMERIC(5,2) DEFAULT 0,
  open_rate NUMERIC(5,2) DEFAULT 0,
  click_rate NUMERIC(5,2) DEFAULT 0,

  -- Timestamps
  first_read_at TIMESTAMPTZ,
  last_read_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 4. Indexes pour performance
CREATE INDEX IF NOT EXISTS idx_broadcast_messages_status ON broadcast_messages(status);
CREATE INDEX IF NOT EXISTS idx_broadcast_messages_scheduled ON broadcast_messages(scheduled_at) WHERE status = 'scheduled';
CREATE INDEX IF NOT EXISTS idx_broadcast_messages_sender ON broadcast_messages(sender_id);
CREATE INDEX IF NOT EXISTS idx_broadcast_messages_segment ON broadcast_messages(target_segment);
CREATE INDEX IF NOT EXISTS idx_broadcast_messages_created ON broadcast_messages(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_broadcast_recipients_broadcast ON broadcast_recipients(broadcast_id);
CREATE INDEX IF NOT EXISTS idx_broadcast_recipients_user ON broadcast_recipients(user_id);
CREATE INDEX IF NOT EXISTS idx_broadcast_recipients_unread ON broadcast_recipients(user_id, read_at) WHERE read_at IS NULL;

-- 5. RLS Policies
ALTER TABLE broadcast_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE broadcast_recipients ENABLE ROW LEVEL SECURITY;
ALTER TABLE broadcast_metrics ENABLE ROW LEVEL SECURITY;

-- Admins/PDG peuvent tout voir et créer
CREATE POLICY "Admins can manage broadcasts" ON broadcast_messages
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM profiles
      WHERE id = auth.uid()
      AND role IN ('admin', 'pdg', 'ceo')
    )
  );

-- Les utilisateurs peuvent voir les broadcasts qui les ciblent
CREATE POLICY "Users can view their broadcasts" ON broadcast_recipients
  FOR SELECT USING (user_id = auth.uid());

CREATE POLICY "Users can update their read status" ON broadcast_recipients
  FOR UPDATE USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "System can insert recipients" ON broadcast_recipients
  FOR INSERT WITH CHECK (true);

CREATE POLICY "Admins can view metrics" ON broadcast_metrics
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM profiles
      WHERE id = auth.uid()
      AND role IN ('admin', 'pdg', 'ceo')
    )
  );

-- 6. Fonction pour obtenir les utilisateurs ciblés
CREATE OR REPLACE FUNCTION get_broadcast_target_users(
  p_segment TEXT,
  p_roles TEXT[] DEFAULT '{}',
  p_regions TEXT[] DEFAULT '{}',
  p_user_ids UUID[] DEFAULT '{}'
)
RETURNS TABLE(user_id UUID, user_role TEXT, user_email TEXT, user_name TEXT)
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  RETURN QUERY
  SELECT
    p.id as user_id,
    p.role as user_role,
    p.email as user_email,
    COALESCE(p.full_name, p.first_name || ' ' || p.last_name, p.email) as user_name
  FROM profiles p
  WHERE
    -- Filtre par segment
    CASE
      WHEN p_segment = 'all' THEN true
      WHEN p_segment = 'agents' THEN p.role IN ('agent', 'agent_commercial')
      WHEN p_segment = 'vendors' THEN p.role IN ('vendor', 'vendeur')
      WHEN p_segment = 'clients' THEN p.role IN ('client', 'customer')
      WHEN p_segment = 'drivers' THEN p.role IN ('driver', 'livreur', 'taxi')
      WHEN p_segment = 'admins' THEN p.role IN ('admin', 'pdg', 'ceo')
      WHEN p_segment = 'custom' THEN
        (array_length(p_roles, 1) IS NULL OR p.role = ANY(p_roles))
      ELSE true
    END
    -- Filtre par régions (si spécifié)
    AND (array_length(p_regions, 1) IS NULL OR p.region = ANY(p_regions))
    -- Filtre par IDs spécifiques (si spécifié)
    AND (array_length(p_user_ids, 1) IS NULL OR p.id = ANY(p_user_ids))
    -- Utilisateur actif
    AND COALESCE(p.is_active, true) = true;
END;
$$;

-- 7. Fonction pour envoyer un broadcast
CREATE OR REPLACE FUNCTION send_broadcast_message(
  p_broadcast_id UUID,
  p_sender_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_broadcast broadcast_messages%ROWTYPE;
  v_recipient RECORD;
  v_count INTEGER := 0;
  v_result JSONB;
BEGIN
  -- Récupérer le broadcast
  SELECT * INTO v_broadcast FROM broadcast_messages WHERE id = p_broadcast_id;

  IF v_broadcast IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Broadcast not found');
  END IF;

  IF v_broadcast.status NOT IN ('draft', 'scheduled') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Broadcast already sent or cancelled');
  END IF;

  -- Mettre à jour le statut
  UPDATE broadcast_messages
  SET status = 'sending', updated_at = NOW()
  WHERE id = p_broadcast_id;

  -- Insérer les destinataires
  FOR v_recipient IN
    SELECT * FROM get_broadcast_target_users(
      v_broadcast.target_segment,
      v_broadcast.target_roles,
      v_broadcast.target_regions,
      v_broadcast.target_user_ids
    )
  LOOP
    -- Insérer dans broadcast_recipients
    INSERT INTO broadcast_recipients (broadcast_id, user_id, channel)
    VALUES (p_broadcast_id, v_recipient.user_id, 'internal')
    ON CONFLICT (broadcast_id, user_id) DO NOTHING;

    -- Créer une notification interne
    INSERT INTO user_notifications (
      user_id, type, title, message, data, read
    ) VALUES (
      v_recipient.user_id,
      'system',
      v_broadcast.title,
      LEFT(v_broadcast.content, 200),
      jsonb_build_object(
        'broadcast_id', p_broadcast_id,
        'priority', v_broadcast.priority,
        'message_type', v_broadcast.message_type,
        'image_url', v_broadcast.image_url,
        'link_url', v_broadcast.link_url
      ),
      false
    );

    v_count := v_count + 1;
  END LOOP;

  -- Mettre à jour le statut final
  UPDATE broadcast_messages
  SET
    status = 'sent',
    sent_at = NOW(),
    updated_at = NOW()
  WHERE id = p_broadcast_id;

  -- Créer les métriques initiales
  INSERT INTO broadcast_metrics (broadcast_id, total_recipients, total_delivered)
  VALUES (p_broadcast_id, v_count, v_count)
  ON CONFLICT (broadcast_id) DO UPDATE SET
    total_recipients = v_count,
    total_delivered = v_count,
    updated_at = NOW();

  RETURN jsonb_build_object(
    'success', true,
    'recipients_count', v_count,
    'broadcast_id', p_broadcast_id
  );
END;
$$;

-- 8. Fonction pour créer et envoyer un broadcast
CREATE OR REPLACE FUNCTION create_and_send_broadcast(
  p_title TEXT,
  p_content TEXT,
  p_segment TEXT DEFAULT 'all',
  p_priority TEXT DEFAULT 'normal',
  p_message_type TEXT DEFAULT 'announcement',
  p_image_url TEXT DEFAULT NULL,
  p_link_url TEXT DEFAULT NULL,
  p_link_text TEXT DEFAULT NULL,
  p_scheduled_at TIMESTAMPTZ DEFAULT NULL,
  p_target_roles TEXT[] DEFAULT '{}',
  p_target_regions TEXT[] DEFAULT '{}',
  p_sender_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_broadcast_id UUID;
  v_sender_id UUID;
  v_sender_name TEXT;
  v_result JSONB;
BEGIN
  -- Déterminer l'expéditeur
  v_sender_id := COALESCE(p_sender_id, auth.uid());

  IF v_sender_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Sender not authenticated');
  END IF;

  -- Vérifier les permissions
  IF NOT EXISTS (
    SELECT 1 FROM profiles
    WHERE id = v_sender_id
    AND role IN ('admin', 'pdg', 'ceo')
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Permission denied');
  END IF;

  -- Récupérer le nom de l'expéditeur
  SELECT COALESCE(full_name, first_name || ' ' || last_name, email)
  INTO v_sender_name
  FROM profiles WHERE id = v_sender_id;

  -- Créer le broadcast
  INSERT INTO broadcast_messages (
    sender_id, sender_name, title, content,
    target_segment, target_roles, target_regions,
    priority, message_type,
    image_url, link_url, link_text,
    scheduled_at,
    status
  ) VALUES (
    v_sender_id, v_sender_name, p_title, p_content,
    p_segment, p_target_roles, p_target_regions,
    p_priority, p_message_type,
    p_image_url, p_link_url, p_link_text,
    p_scheduled_at,
    CASE WHEN p_scheduled_at IS NOT NULL AND p_scheduled_at > NOW() THEN 'scheduled' ELSE 'draft' END
  )
  RETURNING id INTO v_broadcast_id;

  -- Si pas de planification, envoyer immédiatement
  IF p_scheduled_at IS NULL OR p_scheduled_at <= NOW() THEN
    v_result := send_broadcast_message(v_broadcast_id, v_sender_id);
    RETURN v_result || jsonb_build_object('broadcast_id', v_broadcast_id);
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'broadcast_id', v_broadcast_id,
    'status', 'scheduled',
    'scheduled_at', p_scheduled_at
  );
END;
$$;

-- 9. Fonction pour obtenir les broadcasts d'un utilisateur
CREATE OR REPLACE FUNCTION get_user_broadcasts(
  p_user_id UUID DEFAULT NULL,
  p_unread_only BOOLEAN DEFAULT false,
  p_limit INTEGER DEFAULT 20
)
RETURNS TABLE(
  broadcast_id UUID,
  title TEXT,
  content TEXT,
  image_url TEXT,
  link_url TEXT,
  link_text TEXT,
  priority TEXT,
  message_type TEXT,
  sender_name TEXT,
  sent_at TIMESTAMPTZ,
  read_at TIMESTAMPTZ,
  is_read BOOLEAN
)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_user_id UUID;
BEGIN
  v_user_id := COALESCE(p_user_id, auth.uid());

  RETURN QUERY
  SELECT
    bm.id as broadcast_id,
    bm.title,
    bm.content,
    bm.image_url,
    bm.link_url,
    bm.link_text,
    bm.priority,
    bm.message_type,
    bm.sender_name,
    bm.sent_at,
    br.read_at,
    (br.read_at IS NOT NULL) as is_read
  FROM broadcast_messages bm
  JOIN broadcast_recipients br ON br.broadcast_id = bm.id
  WHERE br.user_id = v_user_id
    AND bm.status = 'sent'
    AND (NOT p_unread_only OR br.read_at IS NULL)
    AND (bm.expires_at IS NULL OR bm.expires_at > NOW())
  ORDER BY
    CASE WHEN bm.priority = 'urgent' THEN 0
         WHEN bm.priority = 'high' THEN 1
         ELSE 2 END,
    bm.sent_at DESC
  LIMIT p_limit;
END;
$$;

-- 10. Fonction pour marquer comme lu
CREATE OR REPLACE FUNCTION mark_broadcast_read(p_broadcast_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_user_id UUID;
BEGIN
  v_user_id := auth.uid();

  IF v_user_id IS NULL THEN
    RETURN false;
  END IF;

  UPDATE broadcast_recipients
  SET read_at = NOW()
  WHERE broadcast_id = p_broadcast_id
    AND user_id = v_user_id
    AND read_at IS NULL;

  -- Mettre à jour les métriques
  UPDATE broadcast_metrics
  SET
    total_read = total_read + 1,
    open_rate = ROUND((total_read + 1)::NUMERIC / NULLIF(total_recipients, 0) * 100, 2),
    last_read_at = NOW(),
    first_read_at = COALESCE(first_read_at, NOW()),
    updated_at = NOW()
  WHERE broadcast_id = p_broadcast_id;

  RETURN true;
END;
$$;

-- 11. Fonction pour le dashboard admin
CREATE OR REPLACE FUNCTION get_broadcast_dashboard()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
    'total_broadcasts', (SELECT COUNT(*) FROM broadcast_messages),
    'sent_today', (SELECT COUNT(*) FROM broadcast_messages WHERE sent_at::date = CURRENT_DATE),
    'scheduled', (SELECT COUNT(*) FROM broadcast_messages WHERE status = 'scheduled'),
    'avg_open_rate', (SELECT ROUND(AVG(open_rate), 2) FROM broadcast_metrics WHERE total_recipients > 0),
    'total_recipients_today', (
      SELECT COALESCE(SUM(total_recipients), 0)
      FROM broadcast_metrics bm
      JOIN broadcast_messages b ON b.id = bm.broadcast_id
      WHERE b.sent_at::date = CURRENT_DATE
    ),
    'recent_broadcasts', (
      SELECT COALESCE(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      FROM (
        SELECT
          bm.id, bm.title, bm.target_segment, bm.priority,
          bm.status, bm.sent_at, bm.sender_name,
          COALESCE(m.total_recipients, 0) as recipients,
          COALESCE(m.open_rate, 0) as open_rate
        FROM broadcast_messages bm
        LEFT JOIN broadcast_metrics m ON m.broadcast_id = bm.id
        ORDER BY bm.created_at DESC
        LIMIT 10
      ) t
    )
  ) INTO v_result;

  RETURN v_result;
END;
$$;

-- 12. Trigger pour mettre à jour updated_at
CREATE OR REPLACE FUNCTION update_broadcast_timestamp()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tr_broadcast_messages_updated
  BEFORE UPDATE ON broadcast_messages
  FOR EACH ROW EXECUTE FUNCTION update_broadcast_timestamp();

-- 13. Activer Realtime
ALTER PUBLICATION supabase_realtime ADD TABLE broadcast_messages;
ALTER PUBLICATION supabase_realtime ADD TABLE broadcast_recipients;

-- 14. Grants
GRANT EXECUTE ON FUNCTION get_broadcast_target_users TO authenticated;
GRANT EXECUTE ON FUNCTION send_broadcast_message TO authenticated;
GRANT EXECUTE ON FUNCTION create_and_send_broadcast TO authenticated;
GRANT EXECUTE ON FUNCTION get_user_broadcasts TO authenticated;
GRANT EXECUTE ON FUNCTION mark_broadcast_read TO authenticated;
GRANT EXECUTE ON FUNCTION get_broadcast_dashboard TO authenticated;

COMMENT ON TABLE broadcast_messages IS 'Messages de diffusion globaux/ciblés envoyés par les administrateurs';
COMMENT ON TABLE broadcast_recipients IS 'Suivi des réceptions et lectures des broadcasts';
COMMENT ON TABLE broadcast_metrics IS 'Métriques agrégées des broadcasts';
