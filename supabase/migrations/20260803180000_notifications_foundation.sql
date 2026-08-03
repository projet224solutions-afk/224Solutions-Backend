-- ═══════════════════════════════════════════════════════════════════════════════
-- NOTIFICATIONS — fondation : liens/catégories + tokens push + préférences + point unique
-- ═══════════════════════════════════════════════════════════════════════════════
-- Base de l'upgrade (push app fermée + centre + préférences + groupement). Sûr + prouvable en SQL.
-- Le PUSH FCM réel (service worker + envoi serveur + test appareil) et les UI (centre, préférences)
-- se branchent DESSUS en session dédiée (test §1 sur appareil requis).

-- ── 2.1 Enrichir notifications : lien cliquable + catégorie + read_at ──────────
ALTER TABLE public.notifications
  ADD COLUMN IF NOT EXISTS link     text,
  ADD COLUMN IF NOT EXISTS category text,
  ADD COLUMN IF NOT EXISTS read_at  timestamptz;

-- ── 1.1 Tokens push (multi-appareils par user) ────────────────────────────────
CREATE TABLE IF NOT EXISTS public.push_tokens (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL,
  token       text NOT NULL UNIQUE,
  platform    text NOT NULL DEFAULT 'web' CHECK (platform IN ('web','android','ios')),
  is_valid    boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_push_tokens_user ON public.push_tokens(user_id) WHERE is_valid;
ALTER TABLE public.push_tokens ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='push_tokens' AND policyname='push_tokens_owner') THEN
    CREATE POLICY push_tokens_owner ON public.push_tokens FOR ALL
      USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());
  END IF;
END $$;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.push_tokens TO authenticated;

-- ── 3.1 Préférences par catégorie + canal (défaut TOUT activé = absence de ligne) ──
CREATE TABLE IF NOT EXISTS public.notification_preferences (
  user_id  uuid NOT NULL,
  category text NOT NULL,
  in_app   boolean NOT NULL DEFAULT true,
  push     boolean NOT NULL DEFAULT true,
  sound    boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, category)
);
ALTER TABLE public.notification_preferences ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='notification_preferences' AND policyname='notif_prefs_owner') THEN
    CREATE POLICY notif_prefs_owner ON public.notification_preferences FOR ALL
      USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());
  END IF;
END $$;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.notification_preferences TO authenticated;

-- ── Préférence effective (canal) : les catégories CRITIQUES restent TOUJOURS actives ──
CREATE OR REPLACE FUNCTION public.notification_channel_enabled(p_user uuid, p_category text, p_channel text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT CASE
    -- Critiques (argent/sécurité) : jamais coupables.
    WHEN COALESCE(p_category,'system') IN ('payment','security') THEN true
    ELSE COALESCE((
      SELECT CASE p_channel WHEN 'push' THEN push WHEN 'sound' THEN sound ELSE in_app END
      FROM public.notification_preferences
      WHERE user_id = p_user AND category = p_category
    ), true)  -- pas de ligne → tout activé par défaut
  END;
$$;

-- ── POINT UNIQUE de création de notif (évite la double implémentation) ─────────
-- Écrit la notif (avec link + category) ; le PUSH FCM se branchera ici (send_push) en session dédiée.
CREATE OR REPLACE FUNCTION public.create_notification(
  p_user_id uuid, p_title text, p_body text,
  p_type text DEFAULT 'system', p_category text DEFAULT 'system',
  p_link text DEFAULT NULL, p_metadata jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_id uuid;
BEGIN
  IF p_user_id IS NULL THEN RETURN NULL; END IF;
  INSERT INTO public.notifications (user_id, title, message, type, category, link, metadata)
  VALUES (
    p_user_id, p_title, p_body, p_type, COALESCE(p_category,'system'), p_link,
    -- link aussi dans metadata → getNotificationLink (deeplink) le lit déjà.
    COALESCE(p_metadata,'{}'::jsonb) || CASE WHEN p_link IS NOT NULL THEN jsonb_build_object('link', p_link) ELSE '{}'::jsonb END)
  RETURNING id INTO v_id;
  -- TODO(session dédiée) : PERFORM send_push(p_user_id, p_title, p_body, p_link, p_metadata)
  --   → pousse FCM vers push_tokens si notification_channel_enabled(p_user_id, p_category, 'push').
  RETURN v_id;
END; $$;

REVOKE ALL ON FUNCTION public.create_notification(uuid,text,text,text,text,text,jsonb) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_notification(uuid,text,text,text,text,text,jsonb) TO service_role;
