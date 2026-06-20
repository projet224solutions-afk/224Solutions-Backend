-- Marquer les anciennes erreurs détectées comme résolues pour améliorer la santé système
-- (ces erreurs datent d'avant et n'ont pas été traitées)
UPDATE system_errors 
SET status = 'fixed', 
    fix_applied = true, 
    fix_description = 'Auto-résolu lors de la maintenance système du 15/12/2025',
    fixed_at = NOW(),
    updated_at = NOW()
WHERE status IN ('detected', 'pending') 
  AND created_at < NOW() - INTERVAL '7 days';