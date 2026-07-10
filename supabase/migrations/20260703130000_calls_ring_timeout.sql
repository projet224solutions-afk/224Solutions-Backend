-- ☎️ CALLS : filet de sécurité serveur pour les appels non répondus
-- ─────────────────────────────────────────────────────────────────────────────
-- Le timeout CLIENT (useStartAgoraCall, 45 s) passe déjà l'appel en 'missed' si
-- l'appelant reste connecté. Ce filet SERVEUR couvre le cas où l'appelant a fermé
-- l'app / perdu le réseau : tout appel resté 'ringing' > 60 s passe en 'missed'
-- (l'écran du récepteur se ferme via realtime — TERMINAL inclut 'missed').
-- Colonnes réelles vérifiées dans types.ts : calls(status, started_at, ended_at).

CREATE OR REPLACE FUNCTION public.expire_stale_ringing_calls()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE public.calls
  SET status = 'missed', ended_at = now()
  WHERE status = 'ringing'
    AND started_at < now() - interval '60 seconds';
$$;

-- SECURITY DEFINER sensible → jamais exposée aux clients (règle CLAUDE.md).
REVOKE EXECUTE ON FUNCTION public.expire_stale_ringing_calls() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.expire_stale_ringing_calls() FROM anon;
REVOKE EXECUTE ON FUNCTION public.expire_stale_ringing_calls() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.expire_stale_ringing_calls() TO service_role;

-- Planification : toutes les minutes SI pg_cron est disponible sur l'instance.
-- Sinon (bloc DO silencieux ci-dessous inopérant), appeler la fonction depuis un
-- cron externe (backend Node : job « calls.expire-ringing » chaque minute via
-- supabaseAdmin.rpc('expire_stale_ringing_calls')) — la fonction est prête.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    -- Idempotent : replanifie si le job existe déjà.
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'expire-stale-ringing-calls';
    PERFORM cron.schedule(
      'expire-stale-ringing-calls',
      '* * * * *',
      $job$SELECT public.expire_stale_ringing_calls();$job$
    );
  ELSE
    RAISE NOTICE 'pg_cron absent : planifier expire_stale_ringing_calls() via un cron externe (voir commentaire).';
  END IF;
END;
$$;
