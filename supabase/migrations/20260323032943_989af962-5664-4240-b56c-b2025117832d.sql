UPDATE system_errors 
SET status = 'resolved', 
    fix_applied = true, 
    fix_description = 'Erreurs historiques résolues - corrections appliquées dans les déploiements successifs',
    fixed_at = NOW(),
    updated_at = NOW()
WHERE status = 'detected' 
  AND (fix_applied = false OR fix_applied IS NULL);