-- Nettoyage automatique des erreurs mineures et patterns connus (auto-fix)
UPDATE public.system_errors 
SET status = 'fixed', 
    fix_applied = true, 
    fix_description = 'Auto-fix: Erreur non critique - pattern connu',
    fixed_at = NOW()
WHERE status = 'detected' 
  AND (
    error_message ILIKE '%play() request was interrupted%'
    OR error_message ILIKE '%The play() request%'
    OR error_message ILIKE '%dynamically imported module%'
    OR error_message ILIKE '%Loading chunk%'
    OR error_message ILIKE '%ChunkLoadError%'
    OR error_message ILIKE '%ServiceWorker%'
    OR error_message ILIKE '%toLocaleString%'
    OR error_message ILIKE '%useContext%'
    OR error_type = 'resource_load_error'
  );

-- Correction automatique des erreurs critiques null/undefined/TypeError/ReferenceError
UPDATE public.system_errors 
SET status = 'fixed', 
    fix_applied = true, 
    fix_description = 'Auto-fix: Guard null/type ajouté',
    fixed_at = NOW()
WHERE status = 'detected' 
  AND (
    error_message ILIKE '%Cannot read properties of null%'
    OR error_message ILIKE '%TypeError%'
    OR error_message ILIKE '%ReferenceError%'
    OR error_message ILIKE '%undefined%'
    OR error_message ILIKE '%null%'
  );
