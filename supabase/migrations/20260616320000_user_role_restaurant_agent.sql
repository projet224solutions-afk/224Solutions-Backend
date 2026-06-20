-- ============================================================================
-- Ajoute la valeur 'restaurant_agent' à l'enum user_role.
-- Sans elle, l'upsert du profil de l'agent restaurant échouait silencieusement →
-- l'agent se retrouvait avec le rôle par défaut (client) et était redirigé vers
-- l'interface client au lieu de son interface agent dédiée.
--
-- ⚠️ À APPLIQUER SEUL (un ALTER TYPE ... ADD VALUE ne peut pas être utilisé dans la
-- même transaction que des requêtes qui s'en servent). Appliquer la migration de
-- correction des profils (20260616330000) DANS UN SECOND temps.
-- ============================================================================

ALTER TYPE public.user_role ADD VALUE IF NOT EXISTS 'restaurant_agent';
