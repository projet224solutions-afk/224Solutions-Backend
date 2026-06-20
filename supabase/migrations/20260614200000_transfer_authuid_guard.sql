-- ============================================================================
-- 🔴 Phase 2 — garde auth.uid() sur les transferts wallet (anti-vol)
-- ----------------------------------------------------------------------------
-- Les 2 fonctions de transfert utilisées par le frontend débitent le wallet de
-- `p_sender_*` SANS vérifier que l'appelant en est le propriétaire, et étaient
-- exécutables par anon → un anonyme pouvait VIDER n'importe quel wallet.
--
-- APPROCHE SÛRE (pas de réécriture du corps métier) : on RENOMME la fonction
-- existante en `_core` (préservée à l'identique) et on crée un WRAPPER de même
-- nom/signature qui :
--   1) vérifie que l'appelant est bien l'expéditeur (auth.uid() = sender), ou le
--      backend (service_role) ;
--   2) délègue au `_core` inchangé.
-- Résultat : les transferts légitimes du front (user connecté = expéditeur)
-- continuent ; anon et tout transfert cross-user sont refusés. Front INCHANGÉ.
--
-- Le backend n'appelle PAS ces fonctions (vérifié) ; service_role reste toléré par
-- prudence. Les surcharges NON utilisées par le front sont simplement verrouillées.
-- Rejouable de façon raisonnable (les ALTER ... RENAME échouent si déjà renommées →
-- exécuter une seule fois ; en cas de rejeu, commenter les 2 blocs ALTER).
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────
-- 1) process_wallet_transfer_with_fees(text,text,numeric,varchar,text)  [par code]
-- ─────────────────────────────────────────────────────────────────────────
ALTER FUNCTION public.process_wallet_transfer_with_fees(text, text, numeric, varchar, text)
  RENAME TO process_wallet_transfer_with_fees_core;

CREATE OR REPLACE FUNCTION public.process_wallet_transfer_with_fees(
  p_sender_code text,
  p_receiver_code text,
  p_amount numeric,
  p_currency varchar DEFAULT 'GNF',
  p_description text DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sender uuid;
  v_role   text := auth.jwt() ->> 'role';
BEGIN
  v_sender := find_user_by_code(p_sender_code);
  -- Autorisé si backend (service_role) OU appelant = propriétaire du wallet expéditeur.
  IF COALESCE(v_role, 'anon') <> 'service_role'
     AND (auth.uid() IS NULL OR auth.uid() IS DISTINCT FROM v_sender) THEN
    RETURN json_build_object('success', false,
      'error', 'Non autorisé : vous ne pouvez transférer que depuis votre propre wallet');
  END IF;
  RETURN public.process_wallet_transfer_with_fees_core(
    p_sender_code, p_receiver_code, p_amount, p_currency, p_description);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.process_wallet_transfer_with_fees_core(text,text,numeric,varchar,text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.process_wallet_transfer_with_fees_core(text,text,numeric,varchar,text) TO service_role;
REVOKE EXECUTE ON FUNCTION public.process_wallet_transfer_with_fees(text,text,numeric,varchar,text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.process_wallet_transfer_with_fees(text,text,numeric,varchar,text) TO authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────
-- 2) process_secure_wallet_transfer(uuid,uuid,numeric,text,text,text)  [user→bureau]
-- ─────────────────────────────────────────────────────────────────────────
ALTER FUNCTION public.process_secure_wallet_transfer(uuid, uuid, numeric, text, text, text)
  RENAME TO process_secure_wallet_transfer_core;

CREATE OR REPLACE FUNCTION public.process_secure_wallet_transfer(
  p_sender_id uuid,
  p_receiver_id uuid,
  p_amount numeric,
  p_description text DEFAULT NULL,
  p_sender_type text DEFAULT 'user',
  p_receiver_type text DEFAULT 'user'
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sender_user uuid;
  v_role text := auth.jwt() ->> 'role';
BEGIN
  v_sender_user := CASE p_sender_type
    WHEN 'agent'  THEN COALESCE((SELECT user_id FROM agents_management WHERE id = p_sender_id), p_sender_id)
    WHEN 'bureau' THEN NULL  -- expéditeur bureau (session non-Supabase) → backend uniquement
    ELSE p_sender_id
  END;
  IF COALESCE(v_role, 'anon') <> 'service_role'
     AND (p_sender_type = 'bureau' OR auth.uid() IS NULL OR auth.uid() IS DISTINCT FROM v_sender_user) THEN
    RETURN json_build_object('success', false,
      'error', 'Non autorisé : transfert uniquement depuis votre propre wallet');
  END IF;
  RETURN public.process_secure_wallet_transfer_core(
    p_sender_id, p_receiver_id, p_amount, p_description, p_sender_type, p_receiver_type);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.process_secure_wallet_transfer_core(uuid,uuid,numeric,text,text,text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.process_secure_wallet_transfer_core(uuid,uuid,numeric,text,text,text) TO service_role;
REVOKE EXECUTE ON FUNCTION public.process_secure_wallet_transfer(uuid,uuid,numeric,text,text,text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.process_secure_wallet_transfer(uuid,uuid,numeric,text,text,text) TO authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────
-- 3) Surcharges NON utilisées par le front → verrouillage simple (service_role only)
-- ─────────────────────────────────────────────────────────────────────────
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT oid::regprocedure AS sig FROM pg_proc
    WHERE pronamespace = 'public'::regnamespace
      AND proname IN ('process_wallet_transfer_with_fees','process_secure_wallet_transfer')
      AND oid::regprocedure::text IN (
        'process_wallet_transfer_with_fees(uuid,uuid,numeric,text)',
        'process_secure_wallet_transfer(uuid,text,uuid,text,numeric,text)')
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', r.sig);
    EXECUTE format('GRANT  EXECUTE ON FUNCTION %s TO service_role', r.sig);
  END LOOP;
END $$;

SELECT 'Garde auth.uid() posé sur les 2 transferts front (wrapper→_core) + surcharges verrouillées.' AS status;
