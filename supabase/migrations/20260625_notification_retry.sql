-- supabase/migrations/20260625_notification_retry.sql
-- File de retry pour les notifications SMS/email en échec (3 tentatives, backoff 5min/15min/1h).
BEGIN;

CREATE TABLE IF NOT EXISTS public.notification_retry_queue (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL,
  channel     TEXT NOT NULL CHECK (channel IN ('sms','email')),
  recipient   TEXT NOT NULL,            -- numéro ou email
  message     TEXT NOT NULL,
  subject     TEXT,                     -- pour email uniquement
  attempts    SMALLINT NOT NULL DEFAULT 0,
  max_attempts SMALLINT NOT NULL DEFAULT 3,
  next_retry_at TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '5 minutes',
  last_error  TEXT,
  status      TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','succeeded','failed')),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_notif_retry_pending
  ON public.notification_retry_queue (status, next_retry_at)
  WHERE status = 'pending';

ALTER TABLE public.notification_retry_queue ENABLE ROW LEVEL SECURITY;
-- Lecture/écriture réservée au service_role uniquement
DROP POLICY IF EXISTS "retry_service_only" ON public.notification_retry_queue;
CREATE POLICY "retry_service_only" ON public.notification_retry_queue
  FOR ALL TO service_role USING (true);

DO $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_tables WHERE tablename='notification_retry_queue')
  THEN RAISE EXCEPTION 'TABLE notification_retry_queue manquante'; END IF;
  RAISE NOTICE '✅ notification_retry_queue créée';
END; $$;

COMMIT;
