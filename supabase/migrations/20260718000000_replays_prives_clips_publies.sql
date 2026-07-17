-- ════════════════════════════════════════════════════════════════════════════
-- 🔒 RÈGLE PDG (absolue) : à la fin d'un live, le replay BRUT n'est JAMAIS
-- public. Seuls les CLIPS ≤ 5:00 produits au Studio se publient. Le replay
-- n'est que la matière première, privée, visible de SON vendeur seul.
-- (17-18/07/2026 — Partie 2 du chantier Studio Clips)
-- ════════════════════════════════════════════════════════════════════════════

-- 1) Statut du replay : raw_private par défaut (valeur unique VOLONTAIRE —
--    la règle est absolue ; toute réouverture publique passera par migration).
ALTER TABLE public.live_streams ADD COLUMN IF NOT EXISTS replay_visibility text NOT NULL DEFAULT 'raw_private';
ALTER TABLE public.live_streams DROP CONSTRAINT IF EXISTS live_streams_replay_visibility_check;
ALTER TABLE public.live_streams ADD CONSTRAINT live_streams_replay_visibility_check
  CHECK (replay_visibility IN ('raw_private'));

-- Marqueurs des notifications du parcours guidé (rappel J+1 « créez votre
-- clip » ; avertissement J-3 avant purge de rétention).
ALTER TABLE public.live_streams ADD COLUMN IF NOT EXISTS clip_reminder_sent_at timestamptz;
ALTER TABLE public.live_streams ADD COLUMN IF NOT EXISTS replay_expiry_notified_at timestamptz;

-- 2) RLS : le PUBLIC ne voit que les lives EN COURS ; les replays (ended)
--    ne sont visibles que de leur vendeur. (Avant : tout replay non expiré
--    était lisible par tous — surface fermée.)
DROP POLICY IF EXISTS live_streams_public_read ON public.live_streams;
CREATE POLICY live_streams_public_read ON public.live_streams
  FOR SELECT
  USING (status = 'live' OR vendor_user_id = auth.uid());

-- 3) Clips : la PUBLICATION est un choix du vendeur (défaut ON à la création,
--    posé par le backend) ; lecture publique = clips prêts ET publiés SEULEMENT.
ALTER TABLE public.live_clips ADD COLUMN IF NOT EXISTS is_published boolean NOT NULL DEFAULT false;
CREATE INDEX IF NOT EXISTS idx_live_clips_published
  ON public.live_clips (vendor_id, created_at DESC) WHERE status = 'ready' AND is_published = true;

ALTER TABLE public.live_clips ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS live_clips_public_read ON public.live_clips;
CREATE POLICY live_clips_public_read ON public.live_clips
  FOR SELECT
  USING (
    (status = 'ready' AND is_published = true)
    OR vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  );
GRANT SELECT ON public.live_clips TO anon, authenticated;

-- 4) Rétention de la matière première (config PDG, jours).
ALTER TABLE public.clip_config ADD COLUMN IF NOT EXISTS raw_replay_retention_days integer NOT NULL DEFAULT 30;

-- 5) Bucket PRIVÉ des replays bruts (les fichiers publics existants y sont
--    déplacés par le backfill applicatif ; aucune policy storage → accès
--    uniquement par URL signée servie au vendeur propriétaire).
INSERT INTO storage.buckets (id, name, public)
VALUES ('live-replays', 'live-replays', false)
ON CONFLICT (id) DO NOTHING;
