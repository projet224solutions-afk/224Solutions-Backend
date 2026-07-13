-- ============================================================================
-- FIX 42804 « structure of query does not match function result type »
-- au clic « Confirmer » d'un retrait agent-cash (et sur tout dépôt agent-cash).
--
-- CAUSE RACINE
--   public._acash_agent_wallet(uuid) est le SEUL helper RETURNS TABLE du flux
--   agent-cash. Il déclare :
--       RETURNS TABLE(wallet_id bigint, currency text, balance numeric)
--   mais son corps fait  SELECT w.id, w.currency, w.balance FROM public.wallets.
--   Or la table publique wallets (recréée par 20260109000000_fix_wallet_system_complete)
--   a  currency VARCHAR(3)  — pas TEXT. PostgreSQL valide STRICTEMENT la structure
--   d'un RETURN QUERY contre le type déclaré : varchar(3) ≠ text ⇒ 42804.
--   Le retrait (agent_cash_withdrawal) et le dépôt (agent_cash_deposit) appellent
--   tous deux ce helper (lignes 308 et 192 de 20260712110000). Le bug ne s'était
--   jamais déclenché car aucun des deux flux n'avait été exécuté end-to-end avant
--   la création de la page /cash-confirm.
--
-- CORRECTIF
--   Caster explicitement CHAQUE colonne vers le type déclaré dans le RETURN QUERY.
--   - w.currency::text          → aligne varchar(3) sur le text déclaré (LE fix)
--   - w.id::bigint / w.balance::numeric → no-op aujourd'hui (id BIGSERIAL,
--     balance numeric(15,2)), mais blinde le helper contre toute redéfinition
--     future du schéma wallets. Le verrou FOR UPDATE et l'ordre de tri sont
--     strictement INCHANGÉS (les casts en liste de projection n'empêchent pas
--     le FOR UPDATE, qui verrouille la ligne wallets retournée).
--
--   Idempotent (CREATE OR REPLACE). Aucune donnée touchée. Grants ré-affirmés
--   (helper interne : service_role uniquement, jamais anon/authenticated).
-- ============================================================================

CREATE OR REPLACE FUNCTION public._acash_agent_wallet(p_user_id uuid)
RETURNS TABLE(wallet_id bigint, currency text, balance numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RETURN QUERY
  SELECT w.id::bigint, w.currency::text, w.balance::numeric
  FROM public.wallets w
  WHERE w.user_id = p_user_id
  ORDER BY (w.currency = 'GNF') DESC, w.balance DESC, w.updated_at DESC
  LIMIT 1 FOR UPDATE;
END $$;

REVOKE ALL ON FUNCTION public._acash_agent_wallet(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._acash_agent_wallet(uuid) TO service_role;
