-- ============================================================================
-- SERVICE PHARMACIE — PHASE 6 : rappels de prise de médicaments (planification).
--
-- La table medication_reminders existe (Phase 1 : client_id, medication_name, times[],
-- frequency, duration_days, active). On ajoute :
--   • start_date : début du traitement (pour borner la durée duration_days).
--   • medication_reminder_sent : journal anti-doublon (1 notification par créneau/jour),
--     clé primaire (reminder_id, slot_date, slot_time) → idempotence stricte même si le
--     job repasse sur la même fenêtre (multi-worker, redémarrage…).
--
-- Guinée = UTC+0 → l'heure TIME stockée correspond à l'heure locale (pas de conversion).
-- Idempotent.
-- ============================================================================

ALTER TABLE public.medication_reminders
  ADD COLUMN IF NOT EXISTS start_date date NOT NULL DEFAULT current_date;

-- Journal d'envoi : garantit qu'un créneau (rappel × jour × heure) n'est notifié qu'UNE fois.
CREATE TABLE IF NOT EXISTS public.medication_reminder_sent (
  reminder_id uuid NOT NULL REFERENCES public.medication_reminders(id) ON DELETE CASCADE,
  slot_date   date NOT NULL,
  slot_time   time NOT NULL,
  sent_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (reminder_id, slot_date, slot_time)
);

-- Lecture/écriture réservées au service_role (le job backend) ; aucun accès anon/authenticated.
ALTER TABLE public.medication_reminder_sent ENABLE ROW LEVEL SECURITY;

-- Index pour le scan du job : rappels actifs non expirés.
CREATE INDEX IF NOT EXISTS idx_medication_reminders_active
  ON public.medication_reminders (active, start_date) WHERE active = true;

SELECT 'Pharmacie Phase 6 : medication_reminders.start_date + journal anti-doublon medication_reminder_sent.' AS status;
