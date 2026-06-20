-- ============================================================================
-- FIX: Politiques RLS pour les notifications
-- Permet l'insertion par service_role et les utilisateurs
-- ============================================================================

-- 1. Politique INSERT pour service_role (Edge Functions)
CREATE POLICY IF NOT EXISTS "Service role can insert notifications"
  ON public.notifications FOR INSERT
  TO service_role
  WITH CHECK (true);

-- 2. Politique INSERT pour les utilisateurs (auto-notifications)
CREATE POLICY IF NOT EXISTS "Users can create notifications for themselves"
  ON public.notifications FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = user_id);

-- 3. Politique DELETE pour les utilisateurs (supprimer leurs notifications)
CREATE POLICY IF NOT EXISTS "Users can delete their own notifications"
  ON public.notifications FOR DELETE
  TO authenticated
  USING (auth.uid() = user_id);

-- 4. Vérifier/ajouter politique INSERT pour user_fcm_tokens si manquante
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies 
    WHERE tablename = 'user_fcm_tokens' 
    AND policyname = 'Service role can manage FCM tokens'
  ) THEN
    CREATE POLICY "Service role can manage FCM tokens"
      ON public.user_fcm_tokens FOR ALL
      TO service_role
      USING (true)
      WITH CHECK (true);
  END IF;
END $$;

-- ============================================================================
-- 5. ACTIVER REALTIME POUR LES NOTIFICATIONS (CRITIQUE!)
-- Sans cela, les notifications en temps réel ne fonctionnent pas
-- ============================================================================

-- Ajouter la table notifications à la publication Realtime
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables 
    WHERE pubname = 'supabase_realtime' 
    AND tablename = 'notifications'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.notifications;
    RAISE NOTICE 'Table notifications ajoutée à supabase_realtime';
  END IF;
END $$;

-- Ajouter aussi taxi_notifications si elle existe
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'taxi_notifications') THEN
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables 
      WHERE pubname = 'supabase_realtime' 
      AND tablename = 'taxi_notifications'
    ) THEN
      ALTER PUBLICATION supabase_realtime ADD TABLE public.taxi_notifications;
      RAISE NOTICE 'Table taxi_notifications ajoutée à supabase_realtime';
    END IF;
  END IF;
END $$;

-- Ajouter user_fcm_tokens pour sync temps réel des tokens
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'user_fcm_tokens') THEN
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables 
      WHERE pubname = 'supabase_realtime' 
      AND tablename = 'user_fcm_tokens'
    ) THEN
      ALTER PUBLICATION supabase_realtime ADD TABLE public.user_fcm_tokens;
      RAISE NOTICE 'Table user_fcm_tokens ajoutée à supabase_realtime';
    END IF;
  END IF;
END $$;

-- Définir replica identity pour que Realtime puisse envoyer les anciennes valeurs
ALTER TABLE public.notifications REPLICA IDENTITY FULL;

-- ============================================================================
-- 6. Index pour améliorer les performances des requêtes de notifications
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_notifications_user_unread 
  ON public.notifications (user_id, read) 
  WHERE read = false;

CREATE INDEX IF NOT EXISTS idx_notifications_user_created 
  ON public.notifications (user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_notifications_type 
  ON public.notifications (type);

-- ============================================================================
-- 7. Commentaires
-- ============================================================================

COMMENT ON POLICY "Service role can insert notifications" ON public.notifications 
  IS 'Permet aux Edge Functions d''insérer des notifications';

COMMENT ON POLICY "Users can create notifications for themselves" ON public.notifications 
  IS 'Permet aux utilisateurs de créer leurs propres notifications';
