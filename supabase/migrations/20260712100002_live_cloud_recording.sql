-- ════════════════════════════════════════════════════════════════════════════
-- CHANTIER 2 — Replay serveur (Agora Cloud Recording). Colonnes de suivi sur live_streams.
--
-- Le replay est désormais enregistré CÔTÉ SERVEUR par Agora (mode mix → MP4 dans notre bucket
-- GCS), indépendamment du téléphone du vendeur. Ces colonnes portent l'état du recording (pour
-- le stop au /end, le worker filet, et les 5 états affichés dans l'espace Live vendeur).
--
-- `recording_status` est une colonne DÉDIÉE (on ne surcharge PAS `status` dont le CHECK est figé
-- à scheduled/live/ended) : none / recording / processing / ready / failed.
-- ════════════════════════════════════════════════════════════════════════════

ALTER TABLE public.live_streams
  ADD COLUMN IF NOT EXISTS recording_resource_id text,
  ADD COLUMN IF NOT EXISTS recording_sid         text,
  ADD COLUMN IF NOT EXISTS recording_uid         text,
  ADD COLUMN IF NOT EXISTS recording_status      text NOT NULL DEFAULT 'none'
    CHECK (recording_status IN ('none', 'recording', 'processing', 'ready', 'failed'));

CREATE INDEX IF NOT EXISTS idx_live_streams_recording
  ON public.live_streams(recording_status)
  WHERE recording_status IN ('recording', 'processing');
