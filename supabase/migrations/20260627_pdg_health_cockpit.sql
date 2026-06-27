BEGIN;

-- RPC : renvoie en UN appel les compteurs opérationnels critiques du PDG.
-- Lecture seule, réservé admin/pdg/ceo. Chaque sous-compte est défensif
-- (si une table n'existe pas dans un environnement, on renvoie 0 au lieu d'échouer).
CREATE OR REPLACE FUNCTION public.get_pdg_health_cockpit()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role            text;
  v_kyc_pending     integer := 0;
  v_disputes_open   integer := 0;
  v_bcrg_stale      boolean := false;
  v_bcrg_hours      numeric := 0;
  v_escrow_pending  numeric := 0;
BEGIN
  -- Garde : rôles privilégiés réels de l'enum user_role (pas de super_admin)
  SELECT role INTO v_role FROM public.profiles WHERE id = auth.uid();
  IF v_role IS NULL OR v_role NOT IN ('admin','pdg','ceo') THEN
    RETURN jsonb_build_object('error', 'NOT_AUTHORIZED');
  END IF;

  -- KYC vendeurs en attente (défensif)
  BEGIN
    SELECT count(*) INTO v_kyc_pending
    FROM public.vendor_kyc
    WHERE status = 'pending' OR verification_status = 'pending';
  EXCEPTION WHEN undefined_table OR undefined_column THEN v_kyc_pending := 0;
  END;

  -- Litiges escrow ouverts (défensif)
  BEGIN
    SELECT count(*) INTO v_disputes_open
    FROM public.escrow_disputes
    WHERE status IN ('open','pending','under_review');
  EXCEPTION WHEN undefined_table OR undefined_column THEN v_disputes_open := 0;
  END;

  -- Santé BCRG : taux GNF périmé ? (défensif — table fx_health_check)
  BEGIN
    SELECT
      COALESCE(EXTRACT(EPOCH FROM (now() - last_successful_scrape)) / 3600, 999),
      COALESCE(EXTRACT(EPOCH FROM (now() - last_successful_scrape)) / 3600 >= 24, false)
    INTO v_bcrg_hours, v_bcrg_stale
    FROM public.fx_health_check
    WHERE currency_code = 'GNF'
    LIMIT 1;
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    v_bcrg_stale := false; v_bcrg_hours := 0;
  END;

  -- Montant total en séquestre en attente (défensif)
  BEGIN
    SELECT COALESCE(sum(amount), 0) INTO v_escrow_pending
    FROM public.escrow_transactions
    WHERE status IN ('held','pending');
  EXCEPTION WHEN undefined_table OR undefined_column THEN v_escrow_pending := 0;
  END;

  RETURN jsonb_build_object(
    'kyc_pending',    v_kyc_pending,
    'disputes_open',  v_disputes_open,
    'bcrg_stale',     v_bcrg_stale,
    'bcrg_hours',     round(v_bcrg_hours, 1),
    'escrow_pending', v_escrow_pending,
    'generated_at',   now()
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_pdg_health_cockpit() FROM anon;
GRANT  EXECUTE ON FUNCTION public.get_pdg_health_cockpit() TO authenticated, service_role;

DO $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_proc WHERE proname='get_pdg_health_cockpit')
  THEN RAISE EXCEPTION 'RPC get_pdg_health_cockpit absente'; END IF;
  RAISE NOTICE '✅ Migration pdg_health_cockpit OK';
END; $$;

COMMIT;
