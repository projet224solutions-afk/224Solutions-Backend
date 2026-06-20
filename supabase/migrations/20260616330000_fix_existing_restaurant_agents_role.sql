-- ============================================================================
-- Corrige le rôle des agents de restaurant DÉJÀ créés (avant l'ajout de l'enum) :
-- leur profil avait un rôle par défaut (client) → on le passe à 'restaurant_agent'
-- pour qu'ils soient redirigés vers leur interface dédiée.
-- ⚠️ À appliquer APRÈS 20260616320000 (l'enum doit déjà contenir la valeur).
-- ============================================================================

UPDATE public.profiles
SET role = 'restaurant_agent', updated_at = now()
WHERE id IN (SELECT user_id FROM public.restaurant_agents WHERE user_id IS NOT NULL AND is_active = true)
  AND role <> 'restaurant_agent';

SELECT 'Rôle restaurant_agent appliqué aux profils des agents restaurant existants.' AS status;
