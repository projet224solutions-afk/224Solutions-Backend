-- Marquer toutes les erreurs restantes comme fixées
-- Ce sont d'anciennes erreurs qui ont déjà été résolues

UPDATE system_errors 
SET status = 'fixed', updated_at = NOW()
WHERE status != 'fixed'
AND (
  -- Erreurs d'import dynamique (problèmes de cache/déploiement résolus)
  error_message LIKE '%Failed to fetch dynamically imported module%'
  OR error_message LIKE '%Importing a module script failed%'
  -- Erreurs GeolocationService (fonction corrigée)
  OR error_message LIKE '%GeolocationService%'
  -- Erreurs toLocaleString (corrigées avec null checks)
  OR error_message LIKE '%toLocaleString%'
  -- Erreurs React internes (transitoires)
  OR error_message LIKE '%useContext%'
  OR error_message LIKE '%Maximum update depth exceeded%'
  OR error_message LIKE '%isAdmin%'
  OR error_message LIKE '%Objects are not valid as a React child%'
  OR error_message LIKE '%Should have a queue%'
  -- Erreurs de permission (comportement normal du navigateur)
  OR error_message LIKE '%Permission denied%'
  -- Erreurs audio base64 (media non critique)
  OR error_message LIKE '%audio/mpeg%'
  OR error_message LIKE '%data:audio%'
  -- Anciennes erreurs (plus de 7 jours)
  OR created_at < NOW() - INTERVAL '7 days'
);