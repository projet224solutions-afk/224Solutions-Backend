-- ============================================================================
-- BEAUTÉ — Phase 4 : favoris client + suivi des rappels automatiques (J-1 / H-2).
-- RLS : le client gère ses propres favoris. Rejouable.
-- ============================================================================

ALTER TABLE public.beauty_appointments ADD COLUMN IF NOT EXISTS reminder_day_before_sent boolean NOT NULL DEFAULT false;
ALTER TABLE public.beauty_appointments ADD COLUMN IF NOT EXISTS reminder_2h_sent boolean NOT NULL DEFAULT false;

CREATE TABLE IF NOT EXISTS public.beauty_favorites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  professional_service_id uuid NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  created_at timestamptz DEFAULT now(),
  UNIQUE (client_user_id, professional_service_id)
);
CREATE INDEX IF NOT EXISTS idx_beauty_fav_client ON public.beauty_favorites (client_user_id);

ALTER TABLE public.beauty_favorites ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS bfav_own ON public.beauty_favorites;
CREATE POLICY bfav_own ON public.beauty_favorites
  FOR ALL TO authenticated USING (client_user_id = auth.uid()) WITH CHECK (client_user_id = auth.uid());

SELECT 'Beauté Phase 4 : favoris client.' AS status;
