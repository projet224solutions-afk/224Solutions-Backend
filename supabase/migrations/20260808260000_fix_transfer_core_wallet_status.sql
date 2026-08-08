-- ============================================================================
-- 🔴 TRANSFERTS P2P : seconde casse dans le même primitif — colonne inexistante
-- ----------------------------------------------------------------------------
-- Après la correction de `find_user_by_code` (migration 20260808250000), le
-- primitif échoue plus loin :
--
--     42703 column "status" of relation "wallets" does not exist
--
-- La colonne s'appelle `wallet_status` (cf. `initialize_user_wallet`, qui
-- l'utilise correctement). Le primitif crédite le destinataire via
-- `INSERT INTO wallets (..., status)` — donc toute création de wallet
-- destinataire échoue, et avec elle le transfert entier.
--
-- CONCLUSION SUR L'ÉTAT RÉEL : deux erreurs bloquantes distinctes, l'une après
-- l'autre, dans le même chemin. Ce primitif n'a jamais pu s'exécuter avec succès.
-- Les transferts P2P par code étaient inopérants — ce n'est pas une régression
-- introduite par le paramètre `p_commission_bearer`, qui n'a fait que les révéler
-- en appelant réellement la fonction pour la première fois.
--
-- Ce fichier ne corrige QUE le nom de colonne. Aucune logique d'argent modifiée.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fix_core_wallet_status_column()
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_def text; v_avant int; v_apres int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
    AND p.proname = 'process_wallet_transfer_with_fees_core' LIMIT 1;

  v_avant := (length(v_def) - length(replace(v_def, 'currency, status)', ''))) / length('currency, status)');
  v_def := replace(v_def, 'INSERT INTO wallets (user_id, balance, currency, status)',
                          'INSERT INTO wallets (user_id, balance, currency, wallet_status)');
  v_apres := (length(v_def) - length(replace(v_def, 'currency, status)', ''))) / length('currency, status)');

  EXECUTE v_def;
  RETURN format('occurrences corrigées : %s (restantes : %s)', v_avant - v_apres, v_apres);
END; $$;

SELECT public.fix_core_wallet_status_column();
DROP FUNCTION public.fix_core_wallet_status_column();

SELECT 'Primitif de transfert : colonne wallet_status corrigée.' AS status;
