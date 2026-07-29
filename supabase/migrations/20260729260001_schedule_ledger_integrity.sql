-- Planifie le compteur de dérive comptable en HORAIRE (à la minute 30) via pg_cron.
-- Idempotent : cron.schedule met à jour le job s'il existe déjà. Résultats dans
-- ledger_integrity_checks ; alerte critique (system_alerts) au moindre écart.
SELECT cron.schedule('ledger-integrity-hourly', '30 * * * *', $$SELECT public.run_ledger_integrity_check()$$);
