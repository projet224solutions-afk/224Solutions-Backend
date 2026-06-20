-- 🔴 CORRECTIF CRITIQUE — système de commission agent 100% cassé
--
-- Symptôme : tout appel à credit_agent_commission échouait avec
--   « structure of query does not match function result type » (SQLSTATE 42804).
--   → AUCUNE commission agent/sous-agent n'était jamais créditée
--     (agent_commissions_log restait vide malgré les paiements).
--
-- Cause racine : get_user_agent() déclare `agent_name TEXT` dans son RETURNS TABLE,
--   mais la colonne `agents_management.name` est de type `character varying` (varchar).
--   En PL/pgSQL, RETURN QUERY exige une correspondance EXACTE des types : varchar ≠ text
--   → 42804. credit_agent_commission appelle `SELECT * INTO ... FROM get_user_agent(...)`,
--   donc l'erreur remonte et casse toute la chaîne de commission.
--
-- Correctif : caster explicitement `am.name::text` dans les deux branches (direct + affilié).
--   CREATE OR REPLACE non destructif, idempotent, sans changement de signature.

CREATE OR REPLACE FUNCTION public.get_user_agent(p_user_id UUID)
RETURNS TABLE (
  agent_id UUID,
  agent_name TEXT,
  agent_type TEXT,
  commission_rate NUMERIC,
  parent_agent_id UUID,
  source TEXT -- 'direct' ou 'affiliate'
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  -- D'abord vérifier agent_created_users (création directe)
  RETURN QUERY
  SELECT
    am.id AS agent_id,
    am.name::text AS agent_name,
    am.type_agent::text AS agent_type,
    COALESCE(am.commission_rate, am.commission_agent_principal, 20)::NUMERIC AS commission_rate,
    am.parent_agent_id,
    'direct'::TEXT AS source
  FROM agent_created_users acu
  JOIN agents_management am ON am.id = acu.agent_id
  WHERE acu.user_id = p_user_id
    AND am.is_active = true
  LIMIT 1;

  IF FOUND THEN
    RETURN;
  END IF;

  -- Sinon vérifier user_agent_affiliations (lien d'affiliation)
  RETURN QUERY
  SELECT
    am.id AS agent_id,
    am.name::text AS agent_name,
    am.type_agent::text AS agent_type,
    COALESCE(am.commission_rate, am.commission_agent_principal, 20)::NUMERIC AS commission_rate,
    am.parent_agent_id,
    'affiliate'::TEXT AS source
  FROM user_agent_affiliations uaa
  JOIN agents_management am ON am.id = uaa.agent_id
  WHERE uaa.user_id = p_user_id
    AND uaa.is_verified = true
    AND am.is_active = true
  LIMIT 1;
END;
$$;

REVOKE ALL ON FUNCTION public.get_user_agent(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_user_agent(uuid) TO authenticated, service_role;
