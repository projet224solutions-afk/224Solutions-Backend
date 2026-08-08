-- ============================================================================
-- 🔴 TRANSFERTS P2P PAR CODE : CASSÉS EN PRODUCTION — correction
-- ----------------------------------------------------------------------------
-- DÉCOUVERTE (08/08/2026, en branchant le mandat de prélèvement sur le primitif
-- canonique) : `process_wallet_transfer_with_fees` et son `_core` font
--
--     v_sender_id := find_user_by_code(p_sender_code);
--
-- Or `find_user_by_code(text)` renvoie une TABLE de 4 colonnes
-- (user_id, user_type, display_name, identifier), pas un uuid. PostgreSQL tente
-- de caster la ligne entière en uuid et échoue :
--
--     22P02 invalid input syntax for type uuid:
--     "(e2ce9080-…,agent,"Ibrahima…"
--
-- Conséquence : **AUCUN transfert P2P par code ne peut aboutir**. L'échec est à
-- l'exécution, invisible d'un `tsc` ou d'un test de type ; il ne se voit qu'en
-- appelant réellement la fonction — ce que ce chantier a fait pour la première fois.
--
-- Prouvé avant correction (transaction annulée) :
--   PREUVE|transfert_P2P_par_code = 22P02 invalid input syntax for type uuid
--
-- CORRECTIF : lire la colonne, pas la ligne. Aucune autre logique n'est touchée —
-- ni les frais, ni la conversion, ni les plafonds.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.process_wallet_transfer_with_fees(
  p_sender_code text, p_receiver_code text, p_amount numeric,
  p_currency character varying DEFAULT 'GNF'::character varying,
  p_description text DEFAULT NULL::text,
  p_commission_bearer text DEFAULT 'sender'::text
)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_sender uuid;
  v_role   text := auth.jwt() ->> 'role';
BEGIN
  -- ✅ On extrait la COLONNE user_id (avant : la ligne entière → cast uuid impossible).
  SELECT f.user_id INTO v_sender FROM public.find_user_by_code(p_sender_code) f LIMIT 1;
  IF v_sender IS NULL THEN
    RETURN json_build_object('success', false, 'error', 'Expéditeur introuvable');
  END IF;

  -- Autorisé si backend (service_role) OU appelant = propriétaire du wallet expéditeur.
  IF COALESCE(v_role, 'anon') <> 'service_role'
     AND (auth.uid() IS NULL OR auth.uid() IS DISTINCT FROM v_sender) THEN
    RETURN json_build_object('success', false,
      'error', 'Non autorisé : vous ne pouvez transférer que depuis votre propre wallet');
  END IF;

  RETURN public.process_wallet_transfer_with_fees_core(
    p_sender_code, p_receiver_code, p_amount, p_currency, p_description, p_commission_bearer);
END; $$;

-- Même correction dans le cœur : deux assignations, expéditeur et destinataire.
CREATE OR REPLACE FUNCTION public.fix_core_find_user_assignment()
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
    AND p.proname = 'process_wallet_transfer_with_fees_core' LIMIT 1;

  v_def := replace(v_def,
    'v_sender_id := find_user_by_code(p_sender_code);',
    'SELECT f.user_id INTO v_sender_id FROM public.find_user_by_code(p_sender_code) f LIMIT 1;');
  v_def := replace(v_def,
    'v_receiver_id := find_user_by_code(p_receiver_code);',
    'SELECT f.user_id INTO v_receiver_id FROM public.find_user_by_code(p_receiver_code) f LIMIT 1;');

  EXECUTE v_def;
  RETURN 'core corrigé';
END; $$;

SELECT public.fix_core_find_user_assignment();
DROP FUNCTION public.fix_core_find_user_assignment();

REVOKE ALL ON FUNCTION public.process_wallet_transfer_with_fees(text, text, numeric, character varying, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.process_wallet_transfer_with_fees(text, text, numeric, character varying, text, text) TO authenticated, service_role;

SELECT 'Transferts P2P par code réparés (find_user_by_code : colonne, pas ligne).' AS status;
