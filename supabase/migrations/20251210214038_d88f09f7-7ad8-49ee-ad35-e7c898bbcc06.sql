-- Marquer les 6 erreurs critiques restantes comme corrigées (bugs historiques résolus)

UPDATE public.system_errors 
SET status = 'fixed', 
    fix_applied = true, 
    fix_description = 'Erreur React historique - boucle infinie corrigée par refactoring des hooks',
    fixed_at = now()
WHERE id = '5e39d827-a2d3-41c9-ba12-0e77b69d662d';

UPDATE public.system_errors 
SET status = 'fixed', 
    fix_applied = true, 
    fix_description = 'TypeError toLocaleString - ajout de vérifications null/undefined',
    fixed_at = now()
WHERE id IN ('c3e0553c-9d9d-4777-b82e-948fa1e34d83', '249afc9c-d031-4897-857a-632267f5817b');

UPDATE public.system_errors 
SET status = 'fixed', 
    fix_applied = true, 
    fix_description = 'ReferenceError isAdmin - ordre des déclarations corrigé',
    fixed_at = now()
WHERE id = '384a890d-8216-40d8-b17d-dd97373986fa';

UPDATE public.system_errors 
SET status = 'fixed', 
    fix_applied = true, 
    fix_description = 'Object as React child - affichage des coordonnées GPS corrigé',
    fixed_at = now()
WHERE id = 'aa192f18-469d-45b2-83ae-99c7ce4e6675';

UPDATE public.system_errors 
SET status = 'fixed', 
    fix_applied = true, 
    fix_description = 'Bug React interne - résolu par mise à jour des dépendances',
    fixed_at = now()
WHERE id = '234f8797-3b1f-405e-8067-666087ec0747';