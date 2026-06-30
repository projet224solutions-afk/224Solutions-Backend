-- ════════════════════════════════════════════════════════════════════════════
-- SOURCE DE VÉRITÉ UNIQUE du PDG (pour le crédit des revenus ET le débit commission).
-- ════════════════════════════════════════════════════════════════════════════
-- Diagnostic (2026-06-30) : le wallet PDG réel (wallets, user = pdg_management actif,
-- currency 'GNF') est crédité par create_order_core PHASE 6 et débité par
-- credit_agent_commission (Étape 1) — DÉJÀ le même wallet. Les autres « résolutions »
-- (system_settings.pdg_wallet_id en uuid vs wallets.id entier ; role='CEO' absent de
-- l'enum ; record_platform_revenue) sont du code mort/cassé qui ne crédite aucun wallet.
--
-- On fige la résolution dans UNE fonction réutilisable, pour que la généralisation
-- de la commission (proximité) résolve le PDG de façon IDENTIQUE partout. On ne
-- touche PAS au code mort (le « réparer » injecterait des crédits en double).
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

-- Le user PDG actif (source de vérité). 1 seul attendu (vérifié).
CREATE OR REPLACE FUNCTION public.get_pdg_user_id()
RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT user_id FROM public.pdg_management
  WHERE is_active = true
  ORDER BY created_at NULLS LAST
  LIMIT 1;
$$;
REVOKE ALL ON FUNCTION public.get_pdg_user_id() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_pdg_user_id() TO authenticated, service_role;

-- Garantit l'existence du wallet GNF du PDG et renvoie son id (entier, type réel de
-- wallets.id). À utiliser pour crédit ET débit afin que l'argent rentre/sorte du MÊME
-- wallet. Renvoie NULL si aucun PDG actif (l'appelant gère, fail-closed).
CREATE OR REPLACE FUNCTION public.get_pdg_gnf_wallet_id()
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_user uuid := public.get_pdg_user_id();
  v_wallet bigint;
BEGIN
  IF v_user IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT id INTO v_wallet FROM public.wallets
  WHERE user_id = v_user AND currency = 'GNF';
  IF v_wallet IS NULL THEN
    INSERT INTO public.wallets (user_id, balance, currency, wallet_status)
    VALUES (v_user, 0, 'GNF', 'active')
    ON CONFLICT (user_id, currency) DO NOTHING
    RETURNING id INTO v_wallet;
    IF v_wallet IS NULL THEN
      SELECT id INTO v_wallet FROM public.wallets WHERE user_id = v_user AND currency = 'GNF';
    END IF;
  END IF;
  RETURN v_wallet;
END;
$$;
REVOKE ALL ON FUNCTION public.get_pdg_gnf_wallet_id() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_pdg_gnf_wallet_id() TO authenticated, service_role;

-- Diagnostic non bloquant : signaler si la résolution n'est pas déterministe.
DO $$
DECLARE v_count int;
BEGIN
  SELECT count(*) INTO v_count FROM public.pdg_management WHERE is_active = true;
  IF v_count <> 1 THEN
    RAISE WARNING 'pdg_management : % PDG actifs (attendu 1) — résolution PDG ambiguë à clarifier.', v_count;
  ELSE
    RAISE NOTICE '✅ get_pdg_user_id : 1 PDG actif, résolution déterministe';
  END IF;
END $$;

COMMIT;
