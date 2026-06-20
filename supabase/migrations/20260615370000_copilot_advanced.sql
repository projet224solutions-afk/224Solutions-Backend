-- ============================================================================
-- COPILOT 224 — MÉMOIRE STRUCTURÉE + TUTORIELS + FEATURES VUES (PART 2, additif).
-- ----------------------------------------------------------------------------
-- Complète `copilot_memory` (historique brut) par des MÉMOIRES structurées (préférence/
-- fait/action/feedback, importance, tags, expiration) que le copilot réutilise pour
-- personnaliser ses réponses. + suivi des tutoriels complétés et features vues.
-- Ne touche pas `copilot_conversations` (PDG). RLS user own. Rejouable.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.copilot_memories (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  type        text NOT NULL CHECK (type IN ('preference','action','fact','feedback')),
  content     text NOT NULL,
  context     text,
  importance  integer NOT NULL DEFAULT 1 CHECK (importance BETWEEN 1 AND 3),
  tags        text[] NOT NULL DEFAULT '{}',
  expires_at  timestamptz,
  created_at  timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_copilot_memories_user ON public.copilot_memories (user_id, importance DESC, created_at DESC);

CREATE TABLE IF NOT EXISTS public.copilot_tutorials_completed (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  tutorial_id  text NOT NULL,
  completed_at timestamptz DEFAULT now(),
  UNIQUE (user_id, tutorial_id)
);

CREATE TABLE IF NOT EXISTS public.copilot_features_seen (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  feature_id text NOT NULL,
  seen_at    timestamptz DEFAULT now(),
  UNIQUE (user_id, feature_id)
);

ALTER TABLE public.copilot_memories            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.copilot_tutorials_completed ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.copilot_features_seen       ENABLE ROW LEVEL SECURITY;

-- L'utilisateur lit/efface ses propres mémoires ; l'écriture passe par le backend (service_role).
DROP POLICY IF EXISTS copmem_select_own ON public.copilot_memories;
CREATE POLICY copmem_select_own ON public.copilot_memories FOR SELECT TO authenticated USING (user_id = auth.uid());
DROP POLICY IF EXISTS copmem_delete_own ON public.copilot_memories;
CREATE POLICY copmem_delete_own ON public.copilot_memories FOR DELETE TO authenticated USING (user_id = auth.uid());

DROP POLICY IF EXISTS coptut_own ON public.copilot_tutorials_completed;
CREATE POLICY coptut_own ON public.copilot_tutorials_completed FOR ALL TO authenticated USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS copfeat_own ON public.copilot_features_seen;
CREATE POLICY copfeat_own ON public.copilot_features_seen FOR ALL TO authenticated USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

SELECT 'Copilot 224 : mémoires structurées + tutoriels + features vues (additif).' AS status;
