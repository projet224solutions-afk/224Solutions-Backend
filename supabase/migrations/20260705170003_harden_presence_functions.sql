-- ============================================================================
-- 🔒 CORRECTIF : durcissement des fonctions de présence (SECURITY DEFINER)
-- ----------------------------------------------------------------------------
-- BUGS (audit 2026-07-05) sur 20260129172858 :
--   1. update_user_presence est SECURITY DEFINER SANS `SET search_path` (idem
--      get_online_users / presence_heartbeat / auto_mark_offline) → search_path
--      mutable = classe de vuln (hijack de résolution de noms).
--   2. update_user_presence prend p_user_id et NE VÉRIFIE JAMAIS auth.uid() =
--      p_user_id. SECURITY DEFINER contournant la RLS, tout appelant pouvait
--      usurper la présence d'autrui (IDOR de spoof).
--   3. Aucun REVOKE/GRANT : EXECUTE accordé à PUBLIC par défaut → anon pouvait
--      écrire/usurper la présence.
--   4. p_status n'était pas borné à l'enum de statuts connus.
--
-- FIX :
--   • toutes les fonctions : `SET search_path = public`.
--   • update_user_presence : garde `IF p_user_id <> auth.uid() THEN RAISE`,
--     validation p_status ∈ {online,offline,away,busy,in_call}, REVOKE PUBLIC/anon,
--     GRANT authenticated (le check auth.uid() rend l'accès authenticated sûr).
--   • presence_heartbeat : REVOKE PUBLIC/anon, GRANT authenticated (borné au
--     propriétaire — n'écrit que les lignes online de l'appelant via la garde).
-- Idempotent (CREATE OR REPLACE). Signatures inchangées.
-- ============================================================================

-- 1) ── update_user_presence : acteur vérifié + search_path + enum + grants ───
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
    -- Statut borné à l'enum connu (la dérivation is_online côté lecture est déjà
    -- une whitelist, mais on refuse tôt un statut arbitraire).
    IF p_status IS NULL OR p_status NOT IN ('online', 'offline', 'away', 'busy', 'in_call') THEN
        RAISE EXCEPTION 'INVALID_STATUS';
    END IF;

    INSERT INTO user_presence (user_id, status, current_device, custom_status, last_seen, last_active)
    VALUES (p_user_id, p_status, p_device, p_custom_status, NOW(), CASE WHEN p_status != 'offline' THEN NOW() ELSE NULL END)
    ON CONFLICT (user_id)
    DO UPDATE SET
        status = p_status,
        current_device = p_device,
        custom_status = COALESCE(p_custom_status, user_presence.custom_status),
        last_seen = CASE WHEN p_status = 'offline' THEN NOW() ELSE user_presence.last_seen END,
        last_active = CASE WHEN p_status NOT IN ('offline', 'away') THEN NOW() ELSE user_presence.last_active END;
END;
$$;

REVOKE ALL ON FUNCTION update_user_presence(UUID, VARCHAR, VARCHAR, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION update_user_presence(UUID, VARCHAR, VARCHAR, TEXT) TO authenticated;

-- 2) ── get_online_users : search_path (lecture publique de présence conservée) ─
CREATE OR REPLACE FUNCTION get_online_users(p_user_ids UUID[] DEFAULT NULL)
RETURNS TABLE(
    user_id UUID,
    status VARCHAR,
    current_device VARCHAR,
    custom_status TEXT,
    last_seen TIMESTAMPTZ,
    last_active TIMESTAMPTZ,
    is_online BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT
        up.user_id,
        up.status,
        up.current_device,
        up.custom_status,
        up.last_seen,
        up.last_active,
        (up.status IN ('online', 'busy', 'in_call') AND up.last_active > NOW() - INTERVAL '45 seconds') AS is_online
    FROM user_presence up
    WHERE (p_user_ids IS NULL OR up.user_id = ANY(p_user_ids))
      AND up.status != 'offline';
END;
$$;

-- 3) ── presence_heartbeat : search_path + acteur vérifié + grants ────────────
CREATE OR REPLACE FUNCTION presence_heartbeat(p_user_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF p_user_id IS DISTINCT FROM auth.uid() THEN
        RAISE EXCEPTION 'NOT_OWNER';
    END IF;
    UPDATE user_presence
    SET last_active = NOW(), updated_at = NOW()
    WHERE user_id = p_user_id AND status IN ('online', 'busy', 'in_call');
END;
$$;

REVOKE ALL ON FUNCTION presence_heartbeat(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION presence_heartbeat(UUID) TO authenticated;

-- 4) ── auto_mark_offline : search_path (maintenance service_role/cron) ────────
CREATE OR REPLACE FUNCTION auto_mark_offline()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE user_presence
    SET status = 'away', updated_at = NOW()
    WHERE status = 'online'
      AND last_active < NOW() - INTERVAL '3 minutes';

    UPDATE user_presence
    SET status = 'offline', updated_at = NOW()
    WHERE status IN ('online', 'away')
      AND last_active < NOW() - INTERVAL '10 minutes';

    DELETE FROM typing_indicators
    WHERE expires_at < NOW();
END;
$$;

REVOKE ALL ON FUNCTION auto_mark_offline() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION auto_mark_offline() TO service_role;

SELECT 'FIX présence : search_path fixé + update_user_presence/presence_heartbeat vérifient auth.uid()=p_user_id (anti-spoof) + REVOKE PUBLIC/anon + p_status borné.' AS status;
