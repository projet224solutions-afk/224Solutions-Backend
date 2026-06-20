-- Créer une fonction pour obtenir les conversations de messages directs (sans conversation_id)
-- Cette fonction retourne les messages directs formatés comme des conversations

CREATE OR REPLACE FUNCTION get_user_direct_message_conversations(p_user_id UUID)
RETURNS TABLE (
  id TEXT,
  name TEXT,
  type TEXT,
  creator_id UUID,
  last_message_at TIMESTAMP WITH TIME ZONE,
  last_message_preview TEXT,
  unread_count BIGINT,
  participants JSONB,
  created_at TIMESTAMP WITH TIME ZONE,
  other_user_id UUID
) LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  WITH direct_conversations AS (
    SELECT DISTINCT
      CASE 
        WHEN m.sender_id = p_user_id THEN m.recipient_id
        ELSE m.sender_id
      END AS other_user_id,
      MAX(m.created_at) AS last_message_at,
      MIN(m.created_at) AS first_message_at
    FROM messages m
    WHERE m.conversation_id IS NULL
      AND (m.sender_id = p_user_id OR m.recipient_id = p_user_id)
    GROUP BY other_user_id
  ),
  last_messages AS (
    SELECT DISTINCT ON (dc.other_user_id)
      dc.other_user_id,
      m.content as last_message_preview
    FROM direct_conversations dc
    JOIN messages m ON (
      (m.sender_id = p_user_id AND m.recipient_id = dc.other_user_id)
      OR (m.sender_id = dc.other_user_id AND m.recipient_id = p_user_id)
    )
    WHERE m.conversation_id IS NULL
    ORDER BY dc.other_user_id, m.created_at DESC
  ),
  unread_counts AS (
    SELECT 
      dc.other_user_id,
      COUNT(*) as unread_count
    FROM direct_conversations dc
    JOIN messages m ON m.sender_id = dc.other_user_id AND m.recipient_id = p_user_id
    WHERE m.conversation_id IS NULL
      AND m.read_at IS NULL
    GROUP BY dc.other_user_id
  )
  SELECT
    'direct_' || dc.other_user_id::text AS id,
    COALESCE(p.first_name || ' ' || p.last_name, p.email, 'Utilisateur') AS name,
    'private'::text AS type,
    NULL::uuid AS creator_id,
    dc.last_message_at,
    lm.last_message_preview,
    COALESCE(uc.unread_count, 0) AS unread_count,
    jsonb_build_array(
      jsonb_build_object(
        'user_id', dc.other_user_id,
        'first_name', p.first_name,
        'last_name', p.last_name,
        'email', p.email,
        'avatar_url', p.avatar_url
      )
    ) AS participants,
    dc.first_message_at AS created_at,
    dc.other_user_id
  FROM direct_conversations dc
  LEFT JOIN profiles p ON p.id = dc.other_user_id
  LEFT JOIN last_messages lm ON lm.other_user_id = dc.other_user_id
  LEFT JOIN unread_counts uc ON uc.other_user_id = dc.other_user_id
  ORDER BY dc.last_message_at DESC;
END;
$$;