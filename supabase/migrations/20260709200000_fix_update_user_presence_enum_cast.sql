-- ============================================================================
-- 🩹 CORRECTIF PRODUCTION : update_user_presence échouait 400 à CHAQUE battement
-- ----------------------------------------------------------------------------
-- SYMPTÔME (dashboard prod, 24 h) : ~241 000 erreurs/jour, martèlement ~3/s.
-- Source identifiée via edge_logs : 9604/9608 des 400 = POST /rest/v1/rpc/update_user_presence.
--
-- CAUSE RACINE : la colonne user_presence.status est de type ENUM
-- `user_presence_status` (online/offline/away/busy/in_call), mais la fonction
-- (recréée par 20260705170003_harden_presence_functions) assigne le paramètre
-- p_status (VARCHAR) SANS cast → Postgres refuse la conversion implicite :
--   ERROR 42804: column "status" is of type user_presence_status but expression
--                is of type character varying
-- Donc CHAQUE appel RPC échoue. Le frontend (usePresence.ts) retombe alors sur un
-- upsert direct (que PostgREST caste tout seul JSON→enum) → la présence FONCTIONNE
-- quand même, mais chaque heartbeat (30 s × chaque client en ligne) a d'abord
-- généré un 400 = les ~241k erreurs/jour, du gaspillage de ressources facturées.
--
-- FIX MINIMAL : caster p_status::user_presence_status dans l'INSERT et l'UPDATE.
-- Tout le durcissement sécurité de 20260705170003 est CONSERVÉ à l'identique
-- (garde auth.uid(), validation du statut, search_path=public, REVOKE PUBLIC/anon,
-- GRANT authenticated, signature inchangée). CREATE OR REPLACE = idempotent.
-- ============================================================================

CREATE OR REPLACE FUNCTION update_user_presence(
    p_user_id UUID,
    p_status VARCHAR DEFAULT 'online',
    p_device VARCHAR DEFAULT 'web',
    p_custom_status TEXT DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- Ferme l'IDOR : impossible de modifier la présence d'un autre utilisateur.
    IF p_user_id IS DISTINCT FROM auth.uid() THEN
        RAISE EXCEPTION 'NOT_OWNER';
    END IF;
    -- Statut borné à l'enum connu.
    IF p_status IS NULL OR p_status NOT IN ('online', 'offline', 'away', 'busy', 'in_call') THEN
        RAISE EXCEPTION 'INVALID_STATUS';
    END IF;

    -- ⬇️ Cast explicite VARCHAR → enum user_presence_status (la seule différence
    --    avec 20260705170003 : la colonne est un enum, l'implicit cast n'existe pas).
    INSERT INTO user_presence (user_id, status, current_device, custom_status, last_seen, last_active)
    VALUES (
        p_user_id,
        p_status::user_presence_status,
        p_device,
        p_custom_status,
        NOW(),
        CASE WHEN p_status != 'offline' THEN NOW() ELSE NULL END
    )
    ON CONFLICT (user_id)
    DO UPDATE SET
        status = p_status::user_presence_status,
        current_device = p_device,
        custom_status = COALESCE(p_custom_status, user_presence.custom_status),
        last_seen = CASE WHEN p_status = 'offline' THEN NOW() ELSE user_presence.last_seen END,
        last_active = CASE WHEN p_status NOT IN ('offline', 'away') THEN NOW() ELSE user_presence.last_active END;
END;
$$;

-- Grants réaffirmés (identiques à 20260705170003) — l'accès authenticated est sûr
-- grâce à la garde auth.uid() dans le corps.
REVOKE ALL ON FUNCTION update_user_presence(UUID, VARCHAR, VARCHAR, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION update_user_presence(UUID, VARCHAR, VARCHAR, TEXT) TO authenticated;
