-- ============================================================================
-- 🚢 TRANSITAIRE : libellé aligné + icône mojibake réparée
-- ----------------------------------------------------------------------------
-- CONSTAT PDG (capture accueil Proximité) : « Transitaire / Logistique
-- internationale » apparaissait en doublon de la carte « Transitaire », avec un
-- émoji cassé « ðŸš¢ ».
--
-- DEUX CAUSES DISTINCTES, aucune n'étant un doublon de DONNÉES — il n'existe
-- qu'UN seul code `transitaire` :
--   1. côté front, la liste `COVERED` de Proximite.tsx était tenue À LA MAIN et
--      ne contenait pas 'transitaire' → la section « Autres services »
--      réaffichait un type déjà présent dans la grille. Corrigé en DÉRIVANT
--      cette liste des cartes réellement rendues (le bug ne peut plus revenir) ;
--   2. ici : le nom long et l'icône. L'émoji a été inséré en UTF-8 puis relu en
--      latin-1 (« 🚢 » → « ðŸš¢ ») lors de l'application de la migration du pont.
--
-- Le libellé passe à « Transitaire », identique à la carte et à
-- `serviceTypesConfig` : une seule vérité pour un seul métier. Le descriptif
-- long reste dans `description`, qui est fait pour ça.
-- Idempotent.
-- ============================================================================

UPDATE public.service_types
SET name = 'Transitaire',
    -- Émoji par POINT DE CODE (U+1F6A2) : un littéral UTF-8 se fait re-encoder
    -- en chemin et redonne « ðŸš¢ ». chr() est insensible à l'encodage du transport.
    icon = chr(128674),
    description = 'Dédouanement, fret maritime et aérien, groupage, transit inter-États, entreposage.',
    updated_at = now()
WHERE code = 'transitaire';

SELECT code, name, icon,
       (icon LIKE '%Ã%' OR icon LIKE '%ð%') AS icone_cassee
FROM public.service_types WHERE code = 'transitaire';
