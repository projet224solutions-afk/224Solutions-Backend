-- ============================================================================
-- COPILOT 224 — MÉMOIRE PERSISTANTE (Phase 2, ADDITIF).
-- ----------------------------------------------------------------------------
-- Table dédiée à l'historique conversationnel de Copilot224, par utilisateur et par
-- service. NE TOUCHE PAS `copilot_conversations` (spécifique PDG). Écriture par le
-- backend (service_role) ; lecture par l'utilisateur (ses propres messages). Rejouable.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.copilot_memory (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  service    text,
  role       text NOT NULL CHECK (role IN ('user', 'assistant')),
  content    text NOT NULL,
  created_at timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_copilot_memory_user ON public.copilot_memory (user_id, service, created_at DESC);

ALTER TABLE public.copilot_memory ENABLE ROW LEVEL SECURITY;

-- L'utilisateur lit et efface SES propres messages ; l'écriture passe par le backend.
DROP POLICY IF EXISTS copilot_memory_select_own ON public.copilot_memory;
CREATE POLICY copilot_memory_select_own ON public.copilot_memory
  FOR SELECT TO authenticated USING (user_id = auth.uid());
DROP POLICY IF EXISTS copilot_memory_delete_own ON public.copilot_memory;
CREATE POLICY copilot_memory_delete_own ON public.copilot_memory
  FOR DELETE TO authenticated USING (user_id = auth.uid());

SELECT 'Copilot 224 : table mémoire copilot_memory créée (additif, n''affecte pas copilot_conversations PDG).' AS status;
