-- ============================================================================
-- Commentaires de REPLAY + réponses vendeur (page /live/replay/:id).
-- DISTINCT du chat LIVE (éphémère) : ici c'est persistant, modéré, avec réponses.
--
-- Écritures 100% BACKEND (service_role) : le rate-limit (5/min), le calcul de
-- is_vendor (= auteur == vendeur du live) et l'autorisation de suppression sont
-- assurés dans la route. AUCUNE policy INSERT/UPDATE/DELETE client.
-- Lecture publique des commentaires visibles uniquement.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.live_replay_comments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  stream_id uuid NOT NULL REFERENCES public.live_streams(id) ON DELETE CASCADE,
  user_id uuid NOT NULL,
  author_name text,
  content text NOT NULL CHECK (char_length(content) BETWEEN 1 AND 500),
  parent_id uuid REFERENCES public.live_replay_comments(id) ON DELETE CASCADE,
  is_vendor boolean NOT NULL DEFAULT false,
  status text NOT NULL DEFAULT 'visible' CHECK (status IN ('visible','removed')),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_replay_comments_stream ON public.live_replay_comments(stream_id, created_at);
CREATE INDEX IF NOT EXISTS idx_replay_comments_user   ON public.live_replay_comments(user_id, created_at);

ALTER TABLE public.live_replay_comments ENABLE ROW LEVEL SECURITY;

-- Lecture publique des commentaires visibles (les 'removed' sont masqués).
DROP POLICY IF EXISTS replay_comments_public_read ON public.live_replay_comments;
CREATE POLICY replay_comments_public_read ON public.live_replay_comments
  FOR SELECT
  USING (status = 'visible');
-- (Aucune policy d'écriture : INSERT/UPDATE/DELETE passent par le backend service_role.)
