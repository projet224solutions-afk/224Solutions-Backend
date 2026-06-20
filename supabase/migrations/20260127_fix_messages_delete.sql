-- =====================================================
-- FIX: Ajout colonnes suppression messages
-- =====================================================

-- 1. Ajouter les colonnes manquantes à messages
ALTER TABLE messages ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS deleted_for UUID[] DEFAULT '{}';
ALTER TABLE messages ADD COLUMN IF NOT EXISTS reply_to_id UUID;

-- 2. Créer une policy permissive pour UPDATE sur messages
DROP POLICY IF EXISTS "Allow users to update messages" ON messages;
CREATE POLICY "Allow users to update messages" ON messages
    FOR UPDATE USING (
        sender_id = auth.uid() OR recipient_id = auth.uid()
    )
    WITH CHECK (
        sender_id = auth.uid() OR recipient_id = auth.uid()
    );

-- 3. Fonction simplifiée de suppression
CREATE OR REPLACE FUNCTION soft_delete_message(
    p_message_id UUID,
    p_user_id UUID,
    p_delete_for_everyone BOOLEAN DEFAULT FALSE
)
RETURNS BOOLEAN AS $$
DECLARE
    v_sender_id UUID;
BEGIN
    -- Récupérer l'expéditeur
    SELECT sender_id INTO v_sender_id
    FROM messages
    WHERE id = p_message_id;
    
    IF NOT FOUND THEN
        RAISE NOTICE 'Message non trouvé: %', p_message_id;
        RETURN FALSE;
    END IF;
    
    IF p_delete_for_everyone AND v_sender_id = p_user_id THEN
        -- Supprimer pour tout le monde (seulement si expéditeur)
        UPDATE messages
        SET deleted_at = NOW(), content = '[Message supprimé]'
        WHERE id = p_message_id;
        RAISE NOTICE 'Message supprimé pour tous: %', p_message_id;
    ELSE
        -- Supprimer uniquement pour cet utilisateur
        UPDATE messages
        SET deleted_for = array_append(COALESCE(deleted_for, '{}'), p_user_id)
        WHERE id = p_message_id
        AND NOT (p_user_id = ANY(COALESCE(deleted_for, '{}')));
        RAISE NOTICE 'Message supprimé pour utilisateur %: %', p_user_id, p_message_id;
    END IF;
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 4. Donner les permissions d'exécution
GRANT EXECUTE ON FUNCTION soft_delete_message(UUID, UUID, BOOLEAN) TO authenticated;
