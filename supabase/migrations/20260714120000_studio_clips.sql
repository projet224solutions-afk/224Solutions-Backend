-- ============================================================================
-- STUDIO CLIPS 224 (Phase 1) — fabrique de clips promo à partir des replays live.
-- Chantier A1 : schéma + RLS + bibliothèque musicale + config PDG.
--
-- Source des clips : live_streams.replay_url (GCS). Sortie : bucket clips/ (public).
-- Rendu : 'device' (WebCodecs sur le téléphone) ou 'server' (worker ffmpeg EC2).
-- RLS : le vendeur ne voit/crée que SES clips ; lecture PUBLIQUE des colonnes d'affichage
-- des clips 'ready' (nécessaire au partage /clip/:id et à l'aperçu OG).
-- ============================================================================

-- ── 1) Bibliothèque musicale (AUCUN upload vendeur — droits d'auteur) ──
CREATE TABLE IF NOT EXISTS public.clip_music_tracks (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title         text NOT NULL,
  mood          text NOT NULL DEFAULT 'premium'
                  CHECK (mood IN ('énergique','chill','afro','premium')),
  duration_s    integer NOT NULL DEFAULT 0 CHECK (duration_s >= 0),
  url           text NOT NULL,                 -- URL publique (bucket géré par l'admin PDG)
  license_note  text,                          -- provenance / licence libre de droits
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.clip_music_tracks ENABLE ROW LEVEL SECURITY;
-- Lecture publique des pistes actives (le vendeur choisit dans le studio).
DROP POLICY IF EXISTS cmt_public_read ON public.clip_music_tracks;
CREATE POLICY cmt_public_read ON public.clip_music_tracks FOR SELECT
  USING (is_active = true);
-- Écriture : PDG/admin uniquement (écran admin Chantier D). Le service_role bypass la RLS.
DROP POLICY IF EXISTS cmt_admin_write ON public.clip_music_tracks;
CREATE POLICY cmt_admin_write ON public.clip_music_tracks FOR ALL TO authenticated
  USING (public.is_admin_or_pdg()) WITH CHECK (public.is_admin_or_pdg());
REVOKE ALL ON public.clip_music_tracks FROM anon;

-- Seed : structure + 3 entrées de test (option « Sans musique » = gérée côté app, pas de ligne).
-- Le PDG remplacera par la vraie sélection libre de droits via l'écran admin.
INSERT INTO public.clip_music_tracks (title, mood, duration_s, url, license_note, is_active)
VALUES
  ('Test — Énergique',  'énergique', 0, '', 'PLACEHOLDER — remplacer par une piste libre de droits', false),
  ('Test — Chill',      'chill',     0, '', 'PLACEHOLDER — remplacer par une piste libre de droits', false),
  ('Test — Afro',       'afro',      0, '', 'PLACEHOLDER — remplacer par une piste libre de droits', false)
ON CONFLICT DO NOTHING;

-- ── 2) Config PDG (singleton, pattern config existant) ──
CREATE TABLE IF NOT EXISTS public.clip_config (
  id                            boolean PRIMARY KEY DEFAULT true CHECK (id),  -- singleton
  max_clips_per_vendor_per_day  integer NOT NULL DEFAULT 5   CHECK (max_clips_per_vendor_per_day > 0),
  max_clip_duration_s           integer NOT NULL DEFAULT 300 CHECK (max_clip_duration_s BETWEEN 15 AND 900),
  clip_output_height            integer NOT NULL DEFAULT 720 CHECK (clip_output_height IN (480,720,1080)),
  max_source_duration_s         integer NOT NULL DEFAULT 7200,  -- source > 2h refusée
  updated_at                    timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.clip_config (id) VALUES (true) ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.clip_config ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ccfg_public_read ON public.clip_config;
CREATE POLICY ccfg_public_read ON public.clip_config FOR SELECT USING (true);
DROP POLICY IF EXISTS ccfg_admin_write ON public.clip_config;
CREATE POLICY ccfg_admin_write ON public.clip_config FOR ALL TO authenticated
  USING (public.is_admin_or_pdg()) WITH CHECK (public.is_admin_or_pdg());

-- ── 3) Les clips ──
CREATE TABLE IF NOT EXISTS public.live_clips (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id            uuid NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  stream_id            uuid REFERENCES public.live_streams(id) ON DELETE SET NULL,  -- replay source
  title                text NOT NULL DEFAULT 'Clip promo',
  status               text NOT NULL DEFAULT 'queued'
                         CHECK (status IN ('queued','processing','ready','failed')),
  rendered_on          text NOT NULL DEFAULT 'server'
                         CHECK (rendered_on IN ('device','server')),
  progress             smallint NOT NULL DEFAULT 0 CHECK (progress BETWEEN 0 AND 100),
  -- Découpe : jusqu'à 3 segments, total ≤ max_clip_duration_s (vérifié en API + worker).
  segments             jsonb NOT NULL DEFAULT '[]'::jsonb,   -- [{start_s, end_s}]
  overlay              jsonb NOT NULL DEFAULT '{}'::jsonb,    -- {product_id, product_name, price, currency, show_logo}
  music_track_id       uuid REFERENCES public.clip_music_tracks(id) ON DELETE SET NULL,
  cover_time_s         numeric,
  output_url           text,          -- paysage 720p (public)
  output_vertical_url  text,          -- 9:16 (public)
  thumbnail_url        text,          -- couverture JPEG (public)
  duration_s           numeric,
  size_bytes           bigint,
  error                text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_live_clips_vendor  ON public.live_clips (vendor_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_live_clips_status  ON public.live_clips (status) WHERE status IN ('queued','processing');
CREATE INDEX IF NOT EXISTS ix_live_clips_day     ON public.live_clips (vendor_id, created_at);

ALTER TABLE public.live_clips ENABLE ROW LEVEL SECURITY;

-- Le vendeur ne voit/gère QUE ses clips (via vendors.user_id = auth.uid()).
DROP POLICY IF EXISTS lc_owner_all ON public.live_clips;
CREATE POLICY lc_owner_all ON public.live_clips FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.vendors v WHERE v.id = live_clips.vendor_id AND v.user_id = auth.uid()))
  WITH CHECK (EXISTS (SELECT 1 FROM public.vendors v WHERE v.id = live_clips.vendor_id AND v.user_id = auth.uid()));

-- Lecture PUBLIQUE des clips 'ready' (partage /clip/:id + aperçu OG). Colonnes d'affichage
-- uniquement de fait (title, urls, thumbnail, overlay produit) — pas de données sensibles ici.
DROP POLICY IF EXISTS lc_public_ready ON public.live_clips;
CREATE POLICY lc_public_ready ON public.live_clips FOR SELECT
  USING (status = 'ready');

-- PDG : supervision (lecture de tous les clips).
DROP POLICY IF EXISTS lc_pdg_read ON public.live_clips;
CREATE POLICY lc_pdg_read ON public.live_clips FOR SELECT TO authenticated
  USING (public.is_admin_or_pdg());

REVOKE ALL ON public.live_clips FROM anon;
-- anon peut lire (SELECT) via la policy publique 'ready' — grant SELECT explicite (RLS filtre).
GRANT SELECT ON public.live_clips TO anon;

-- ── 4) updated_at auto ──
CREATE OR REPLACE FUNCTION public._clip_touch_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END $$;
DROP TRIGGER IF EXISTS trg_live_clips_touch ON public.live_clips;
CREATE TRIGGER trg_live_clips_touch BEFORE UPDATE ON public.live_clips
  FOR EACH ROW EXECUTE FUNCTION public._clip_touch_updated_at();

COMMENT ON TABLE public.live_clips IS 'Clips promo (Phase 1) générés depuis un replay live. rendered_on=device (WebCodecs) ou server (ffmpeg EC2). Lecture publique des clips ready pour /clip/:id + OG.';
