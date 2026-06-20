-- ============================================================================
-- RETRAIT DU SERVICE ÉDUCATION (demande user) — l'éducation est déjà couverte par la
-- BOUTIQUE DIGITALE. On DÉSACTIVE le type de service 'education' (retiré du catalogue
-- de création) sans supprimer les données (courses/enrollments conservés). Rejouable.
-- ============================================================================

UPDATE public.service_types SET is_active = false WHERE code = 'education';

SELECT 'Service Éducation désactivé (retiré du catalogue ; données courses/inscriptions conservées).' AS status;
