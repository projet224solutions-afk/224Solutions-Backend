-- ════════════════════════════════════════════════════════════════════
-- PARTIE 4.3 — Activer la réplication realtime sur la table calls.
-- Sans ça, un abonnement postgres_changes sur 'calls' ne reçoit RIEN →
-- l'appel entrant n'arrive jamais (« ça ne sonne pas »). Prérequis pour
-- l'écouteur d'appel entrant (callee_id/receiver_id = moi, status 'ringing').
-- Idempotent : ignore si la table est déjà dans la publication.
-- ════════════════════════════════════════════════════════════════════
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.calls;
EXCEPTION
  WHEN duplicate_object THEN
    RAISE NOTICE 'calls déjà dans supabase_realtime — rien à faire';
  WHEN others THEN
    RAISE NOTICE 'ajout calls à supabase_realtime ignoré: %', SQLERRM;
END $$;

-- REPLICA IDENTITY FULL : les payloads UPDATE/DELETE realtime incluent toutes les
-- colonnes (utile pour récupérer receiver_id/metadata côté écouteur).
ALTER TABLE public.calls REPLICA IDENTITY FULL;
