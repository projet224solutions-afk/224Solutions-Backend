BEGIN;

-- Table de suivi de la santé du collecteur BCRG
CREATE TABLE IF NOT EXISTS public.fx_health_check (
  id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  currency_code           TEXT NOT NULL,
  last_successful_scrape  TIMESTAMPTZ,
  last_attempt            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  consecutive_failures    INTEGER NOT NULL DEFAULT 0,
  pdg_alerted_at          TIMESTAMPTZ,
  updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (currency_code)
);

-- Ligne initiale pour GNF (BCRG)
INSERT INTO public.fx_health_check (currency_code, last_successful_scrape, consecutive_failures)
VALUES ('GNF', NOW(), 0)
ON CONFLICT (currency_code) DO NOTHING;

ALTER TABLE public.fx_health_check ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "fx_health_read" ON public.fx_health_check;
CREATE POLICY "fx_health_read" ON public.fx_health_check
  FOR SELECT TO authenticated USING (true);

-- RPC pour enregistrer un succès de scrape BCRG
CREATE OR REPLACE FUNCTION public.record_fx_scrape_success(p_currency text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.fx_health_check (currency_code, last_successful_scrape, last_attempt, consecutive_failures, updated_at)
  VALUES (p_currency, NOW(), NOW(), 0, NOW())
  ON CONFLICT (currency_code) DO UPDATE SET
    last_successful_scrape = NOW(),
    last_attempt           = NOW(),
    consecutive_failures   = 0,
    pdg_alerted_at         = NULL,  -- reset l'alerte
    updated_at             = NOW();
END; $$;

GRANT EXECUTE ON FUNCTION public.record_fx_scrape_success(text) TO service_role;

-- RPC pour enregistrer un échec et déclencher l'alerte PDG si > 24h
CREATE OR REPLACE FUNCTION public.record_fx_scrape_failure(p_currency text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_row             record;
  v_hours_since     numeric;
  v_should_alert    boolean := false;
  v_pdg_user_id     uuid;
BEGIN
  -- Incrémenter les échecs consécutifs
  INSERT INTO public.fx_health_check (currency_code, last_attempt, consecutive_failures, updated_at)
  VALUES (p_currency, NOW(), 1, NOW())
  ON CONFLICT (currency_code) DO UPDATE SET
    last_attempt         = NOW(),
    consecutive_failures = public.fx_health_check.consecutive_failures + 1,
    updated_at           = NOW()
  RETURNING * INTO v_row;

  -- Calculer les heures depuis le dernier succès
  IF v_row.last_successful_scrape IS NOT NULL THEN
    v_hours_since := EXTRACT(EPOCH FROM (NOW() - v_row.last_successful_scrape)) / 3600;
  ELSE
    v_hours_since := 999;
  END IF;

  -- Alerter le PDG si > 24h ET pas déjà alerté dans les 12 dernières heures
  IF v_hours_since >= 24 AND (
    v_row.pdg_alerted_at IS NULL OR
    EXTRACT(EPOCH FROM (NOW() - v_row.pdg_alerted_at)) / 3600 >= 12
  ) THEN
    v_should_alert := true;

    SELECT user_id INTO v_pdg_user_id
    FROM public.pdg_management WHERE is_active = true LIMIT 1;

    IF v_pdg_user_id IS NOT NULL THEN
      INSERT INTO public.notifications (user_id, type, title, message, read, created_at)
      VALUES (
        v_pdg_user_id, 'system',
        '⚠️ Taux BCRG indisponible',
        format('Le site BCRG est inaccessible depuis %s heures (%s échecs consécutifs). Les taux GNF utilisent le dernier fixing officiel. Vérifiez bcrg-guinee.org.',
               round(v_hours_since), v_row.consecutive_failures),
        false, NOW()
      );

      UPDATE public.fx_health_check
      SET pdg_alerted_at = NOW()
      WHERE currency_code = p_currency;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'consecutive_failures', v_row.consecutive_failures,
    'hours_since_success',  round(v_hours_since, 1),
    'pdg_alerted',          v_should_alert
  );
END; $$;

GRANT EXECUTE ON FUNCTION public.record_fx_scrape_failure(text) TO service_role;

DO $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_tables WHERE tablename='fx_health_check') OR
     NOT EXISTS(SELECT 1 FROM pg_proc WHERE proname='record_fx_scrape_success') OR
     NOT EXISTS(SELECT 1 FROM pg_proc WHERE proname='record_fx_scrape_failure')
  THEN RAISE EXCEPTION 'MIGRATION fx_health_check INCOMPLÈTE'; END IF;
  RAISE NOTICE '✅ Migration fx_health_check OK';
END; $$;

COMMIT;
