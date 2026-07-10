-- ============================================================================
-- COPILOTE PRO — FIX 5 : feedback 👍👎 sur les réponses du copilote.
-- Sert au PDG à améliorer les prompts (taux de satisfaction, 👎 récents).
-- Écriture via service_role (endpoint filtre user_id = req.user.id) ; RLS = défense en
-- profondeur : insert/update de SON feedback, lecture réservée admin/PDG.
-- message_ref = id stable du message assistant côté front → un vote MODIFIABLE (up↔down).
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.copilot_feedback (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  service      text,
  message_ref  text,
  question     text,   -- tronquée 300 côté serveur
  reply        text,   -- tronquée 1000 côté serveur
  rating       text NOT NULL CHECK (rating IN ('up', 'down')),
  comment      text,   -- court, optionnel (surtout sur 👎)
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_copilot_feedback_created ON public.copilot_feedback(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_copilot_feedback_rating  ON public.copilot_feedback(rating);
CREATE INDEX IF NOT EXISTS idx_copilot_feedback_service ON public.copilot_feedback(service);
-- Un seul vote par (utilisateur, message) → le vote est modifiable (upsert).
CREATE UNIQUE INDEX IF NOT EXISTS uq_copilot_feedback_user_msg
  ON public.copilot_feedback(user_id, message_ref) WHERE message_ref IS NOT NULL;

ALTER TABLE public.copilot_feedback ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS copilot_feedback_insert_self ON public.copilot_feedback;
CREATE POLICY copilot_feedback_insert_self ON public.copilot_feedback
  FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS copilot_feedback_update_self ON public.copilot_feedback;
CREATE POLICY copilot_feedback_update_self ON public.copilot_feedback
  FOR UPDATE TO authenticated USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

-- Lecture RÉSERVÉE admin/PDG (matière pour améliorer les prompts).
DROP POLICY IF EXISTS copilot_feedback_read_admin ON public.copilot_feedback;
CREATE POLICY copilot_feedback_read_admin ON public.copilot_feedback
  FOR SELECT TO authenticated USING (public.is_admin_or_pdg(auth.uid()));
