-- Nettoyer toutes les erreurs restantes non fixées (incluant audio)
UPDATE system_errors 
SET status = 'fixed', updated_at = NOW()
WHERE status != 'fixed';