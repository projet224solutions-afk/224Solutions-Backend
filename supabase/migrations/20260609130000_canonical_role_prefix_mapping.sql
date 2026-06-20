-- ============================================================================
-- MAPPING CANONIQUE RÔLE → PRÉFIXE ID (générateur complet)
-- ----------------------------------------------------------------------------
-- Problème : generate_custom_id_with_role ne connaissait que client/vendeur/admin/
-- ceo/pdg/livreur/taxi/agent/syndicat/transitaire. TOUT autre rôle tombait sur
-- ELSE = 'CLT' → un vendor_agent / prestataire / actionnaire / sous-agent / worker /
-- bureau futur aurait reçu un préfixe CLIENT (faux). Les IDs existants (VAG0011,
-- USR0017, USR0024) sont eux corrects ; le risque était sur les FUTURS comptes.
--
-- Correctif : CASE complet + normalisation de casse (lower/trim) + ELSE = 'USR'
-- (utilisateur générique, plus 'CLT' qui faisait passer un rôle inconnu pour un client).
-- Le mapping correspond AUX DONNÉES EXISTANTES → aucune renormalisation nécessaire.
-- Le reste de la fonction (compteur id_counters, padding 4, unicité) est inchangé.
-- Non destructif, rejouable.
-- ============================================================================

CREATE OR REPLACE FUNCTION generate_custom_id_with_role(p_role TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_prefix TEXT;
  v_next_num INTEGER;
  v_new_id TEXT;
  v_exists INTEGER;
  v_role TEXT := lower(trim(COALESCE(p_role, 'client')));
BEGIN
  -- Mapping CANONIQUE rôle → préfixe (3 lettres). Couvre tous les rôles du système.
  CASE v_role
    WHEN 'client'        THEN v_prefix := 'CLT';
    WHEN 'customer'      THEN v_prefix := 'CLT';
    WHEN 'vendeur'       THEN v_prefix := 'VND';
    WHEN 'vendor'        THEN v_prefix := 'VND';
    WHEN 'agent'         THEN v_prefix := 'AGT';
    WHEN 'sous-agent'    THEN v_prefix := 'SAG';
    WHEN 'sous_agent'    THEN v_prefix := 'SAG';
    WHEN 'sub_agent'     THEN v_prefix := 'SAG';
    WHEN 'vendor_agent'  THEN v_prefix := 'VAG';
    WHEN 'vendor-agent'  THEN v_prefix := 'VAG';
    WHEN 'chauffeur'     THEN v_prefix := 'DRV';
    WHEN 'driver'        THEN v_prefix := 'DRV';
    WHEN 'taxi'          THEN v_prefix := 'TAX';
    WHEN 'taxi_moto'     THEN v_prefix := 'TAX';
    WHEN 'taxi-moto'     THEN v_prefix := 'TAX';
    WHEN 'livreur'       THEN v_prefix := 'LIV';
    WHEN 'delivery'      THEN v_prefix := 'LIV';
    WHEN 'coursier'      THEN v_prefix := 'LIV';
    WHEN 'bureau'        THEN v_prefix := 'BUR';
    WHEN 'syndicat'      THEN v_prefix := 'BST';
    WHEN 'bureau_syndicat' THEN v_prefix := 'BST';
    WHEN 'admin'         THEN v_prefix := 'ADM';
    WHEN 'administrator' THEN v_prefix := 'ADM';
    WHEN 'pdg'           THEN v_prefix := 'PDG';
    WHEN 'ceo'           THEN v_prefix := 'PDG';
    WHEN 'transitaire'   THEN v_prefix := 'TRS';
    WHEN 'freight'       THEN v_prefix := 'TRS';
    WHEN 'prestataire'   THEN v_prefix := 'USR';   -- pas de préfixe dédié → générique (= données existantes)
    WHEN 'actionnaire'   THEN v_prefix := 'USR';   -- idem
    WHEN 'shareholder'   THEN v_prefix := 'USR';
    WHEN 'worker'        THEN v_prefix := 'WRK';
    WHEN 'employee'      THEN v_prefix := 'WRK';
    WHEN 'membre'        THEN v_prefix := 'MBR';
    WHEN 'member'        THEN v_prefix := 'MBR';
    ELSE                      v_prefix := 'USR';   -- rôle inconnu → générique (PAS client)
  END CASE;

  -- Compteur par préfixe.
  UPDATE id_counters
  SET current_value = current_value + 1, updated_at = NOW()
  WHERE prefix = v_prefix
  RETURNING current_value INTO v_next_num;

  IF v_next_num IS NULL THEN
    SELECT COALESCE(MAX(
      NULLIF(regexp_replace(custom_id, '^' || v_prefix, '', 'i'), '')::INTEGER
    ), 0) INTO v_next_num
    FROM user_ids
    WHERE custom_id LIKE v_prefix || '%';

    v_next_num := v_next_num + 1;

    INSERT INTO id_counters (prefix, current_value, description)
    VALUES (v_prefix, v_next_num, 'Compteur ' || v_prefix)
    ON CONFLICT (prefix) DO UPDATE SET current_value = v_next_num;
  END IF;

  v_new_id := v_prefix || LPAD(v_next_num::TEXT, 4, '0');

  SELECT COUNT(*) INTO v_exists FROM user_ids WHERE custom_id = v_new_id;
  WHILE v_exists > 0 LOOP
    v_next_num := v_next_num + 1;
    v_new_id := v_prefix || LPAD(v_next_num::TEXT, 4, '0');
    SELECT COUNT(*) INTO v_exists FROM user_ids WHERE custom_id = v_new_id;
    UPDATE id_counters SET current_value = v_next_num WHERE prefix = v_prefix;
  END LOOP;

  RETURN v_new_id;
END;
$$;

GRANT EXECUTE ON FUNCTION generate_custom_id_with_role(TEXT) TO authenticated, service_role;

SELECT 'Mapping canonique rôle→préfixe complet (vendor_agent→VAG, prestataire/actionnaire→USR, sous-agent→SAG, worker→WRK, membre→MBR, bureau→BUR, ELSE→USR).' AS status;
