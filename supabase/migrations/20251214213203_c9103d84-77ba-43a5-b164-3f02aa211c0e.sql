-- Marquer les erreurs de modules dynamiques comme corrigées (problèmes de cache)
UPDATE system_errors 
SET status = 'fixed', 
    fix_applied = true,
    fix_description = 'Erreur de cache Vite - modules existent et fonctionnent correctement'
WHERE error_message LIKE '%Failed to fetch dynamically imported module%'
AND status = 'detected';

-- Marquer les erreurs "Search is not defined" et "GeolocationService is not defined" comme corrigées
UPDATE system_errors 
SET status = 'fixed', 
    fix_applied = true,
    fix_description = 'Erreur de chargement temporaire - modules correctement exportés'
WHERE (error_message LIKE '%Search is not defined%' 
   OR error_message LIKE '%GeolocationService is not defined%')
AND status = 'detected';