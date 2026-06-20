-- ============================================================================
-- 🌍 PRIX D'ABONNEMENT PAR PAYS — FONDATION (Modèle B : grilles indépendantes).
-- ----------------------------------------------------------------------------
-- Adapté au schéma RÉEL : profiles (pas `users`), wallet PDG (pas `system_accounts`),
-- service_plans (service_type_id→service_types.code, name=tier). Le prix d'abonnement
-- devient une GRILLE par (pays, service, plan), FIXÉE par l'admin (pas une conversion FX).
-- Le pays est VERROUILLÉ à l'inscription : voyager ne change pas les prix.
--
-- Atomique + blindé : résolveur SECURITY DEFINER (jamais le prix client), RPC admin
-- tout-ou-rien avec motif obligatoire + log, REVOKE FROM PUBLIC sur tout ce qui touche
-- l'argent/identité. Idempotent (rejouable).
-- ============================================================================

-- 1) ── RÉFÉRENTIEL PAYS ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.countries (
  country_code     text PRIMARY KEY,                 -- ISO-2 (GN, SN, FR…)
  country_name     text NOT NULL,
  currency_code    text NOT NULL,                     -- GNF, XOF, EUR…
  currency_symbol  text NOT NULL,
  flag_emoji       text,                              -- 🇬🇳
  payment_methods  text[] NOT NULL DEFAULT '{}',
  is_active        boolean NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.countries (country_code, country_name, currency_code, currency_symbol, flag_emoji, payment_methods, is_active) VALUES
  ('GN','Guinée',         'GNF','FG','🇬🇳', ARRAY['orange_money','mtn_momo','wallet'],                         true),
  ('SN','Sénégal',        'XOF','CFA','🇸🇳',ARRAY['orange_money','wave','free_money','wallet'],                true),
  ('CI','Côte d''Ivoire', 'XOF','CFA','🇨🇮',ARRAY['orange_money','mtn_momo','moov_money','wave','wallet'],     true),
  ('ML','Mali',           'XOF','CFA','🇲🇱',ARRAY['orange_money','moov_money','wallet'],                       true),
  ('FR','France',         'EUR','€', '🇫🇷', ARRAY['card','sepa','wallet'],                                     true),
  ('US','États-Unis',     'USD','$', '🇺🇸', ARRAY['card','wallet'],                                            true),
  ('MA','Maroc',          'MAD','DH','🇲🇦', ARRAY['card','cash_plus','wallet'],                                true)
ON CONFLICT (country_code) DO UPDATE
  SET country_name = EXCLUDED.country_name, currency_code = EXCLUDED.currency_code,
      currency_symbol = EXCLUDED.currency_symbol, flag_emoji = EXCLUDED.flag_emoji,
      payment_methods = EXCLUDED.payment_methods, updated_at = now();

-- 2) ── GRILLE DE PRIX PAR PAYS × SERVICE × PLAN ─────────────────────────────
CREATE TABLE IF NOT EXISTS public.subscription_prices (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  country_code    text NOT NULL REFERENCES public.countries(country_code) ON DELETE CASCADE,
  service_type    text NOT NULL,                        -- 'vendor','driver','menage','pharmacie'…
  plan_code       text NOT NULL,                        -- 'free','basic','pro','premium'
  price           numeric NOT NULL CHECK (price >= 0),  -- DANS la devise du pays
  currency_code   text NOT NULL,
  commission_rate numeric NOT NULL DEFAULT 0 CHECK (commission_rate >= 0 AND commission_rate <= 100),
  billing_cycle   text NOT NULL DEFAULT 'monthly',      -- 'monthly' | 'yearly'
  is_active       boolean NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (country_code, service_type, plan_code, billing_cycle)
);
CREATE INDEX IF NOT EXISTS idx_subprices_lookup ON public.subscription_prices (country_code, service_type, is_active);

-- Seed représentatif (vendor + driver). L'admin ajuste ensuite par l'interface PDG.
-- Devise du pays : prix FIXÉS localement (PAS une conversion du GNF).
INSERT INTO public.subscription_prices (country_code, service_type, plan_code, price, currency_code, commission_rate, billing_cycle) VALUES
  -- Guinée (GNF)
  ('GN','vendor','free',0,        'GNF',5,'monthly'),
  ('GN','vendor','basic',10000,   'GNF',4,'monthly'),
  ('GN','vendor','pro',25000,     'GNF',3,'monthly'),
  ('GN','vendor','premium',50000, 'GNF',2,'monthly'),
  ('GN','driver','free',0,        'GNF',0,'monthly'),
  ('GN','driver','pro',20000,     'GNF',0,'monthly'),
  -- Sénégal / Côte d'Ivoire / Mali (XOF)
  ('SN','vendor','free',0,    'XOF',5,'monthly'),
  ('SN','vendor','pro',1500,  'XOF',3,'monthly'),
  ('SN','vendor','premium',3000,'XOF',2,'monthly'),
  ('CI','vendor','free',0,    'XOF',5,'monthly'),
  ('CI','vendor','pro',1500,  'XOF',3,'monthly'),
  ('CI','vendor','premium',3000,'XOF',2,'monthly'),
  ('ML','vendor','free',0,    'XOF',5,'monthly'),
  ('ML','vendor','pro',1500,  'XOF',3,'monthly'),
  -- France (EUR)
  ('FR','vendor','free',0,    'EUR',5,'monthly'),
  ('FR','vendor','pro',9.99,  'EUR',3,'monthly'),
  ('FR','vendor','premium',19.99,'EUR',2,'monthly'),
  -- USA (USD)
  ('US','vendor','free',0,    'USD',5,'monthly'),
  ('US','vendor','pro',9.99,  'USD',3,'monthly'),
  -- Maroc (MAD)
  ('MA','vendor','free',0,    'MAD',5,'monthly'),
  ('MA','vendor','pro',49,    'MAD',3,'monthly')
ON CONFLICT (country_code, service_type, plan_code, billing_cycle) DO NOTHING;

-- 3) ── COLONNES PAYS VERROUILLÉ SUR profiles ────────────────────────────────
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS country_code   text REFERENCES public.countries(country_code);
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS country_locked boolean NOT NULL DEFAULT false;

-- Backfill prudent depuis l'existant (country / detected_country) → ISO-2 connus.
UPDATE public.profiles SET country_code = CASE
    WHEN upper(coalesce(country, detected_country)) IN ('GN','SN','CI','ML','FR','US','MA') THEN upper(coalesce(country, detected_country))
    WHEN lower(coalesce(country, detected_country)) LIKE '%guin%' THEN 'GN'
    WHEN lower(coalesce(country, detected_country)) LIKE '%séné%' OR lower(coalesce(country, detected_country)) LIKE '%sene%' THEN 'SN'
    WHEN lower(coalesce(country, detected_country)) LIKE '%ivoire%' THEN 'CI'
    WHEN lower(coalesce(country, detected_country)) LIKE '%mali%' THEN 'ML'
    WHEN lower(coalesce(country, detected_country)) LIKE '%fran%' THEN 'FR'
    WHEN lower(coalesce(country, detected_country)) LIKE '%maroc%' OR lower(coalesce(country, detected_country)) LIKE '%moroc%' THEN 'MA'
    ELSE country_code
  END
WHERE country_code IS NULL;

-- 4) ── JOURNAL DES CHANGEMENTS DE PAYS (override admin, traçable) ───────────
CREATE TABLE IF NOT EXISTS public.user_country_change_log (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL,
  old_country  text,
  new_country  text NOT NULL,
  reason       text NOT NULL,
  changed_by   uuid,
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- 5) ── RÉSOLVEUR DE PRIX PAR PAYS VERROUILLÉ (jamais le prix client) ────────
CREATE OR REPLACE FUNCTION public.get_subscription_price_by_country(
  p_user_id uuid, p_service_type text, p_plan text, p_cycle text DEFAULT 'monthly'
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_cc text; v_row public.subscription_prices%ROWTYPE; v_flag text; v_sym text;
BEGIN
  SELECT country_code INTO v_cc FROM public.profiles WHERE id = p_user_id;
  IF v_cc IS NULL THEN RETURN jsonb_build_object('found', false, 'reason', 'NO_COUNTRY'); END IF;

  SELECT * INTO v_row FROM public.subscription_prices
  WHERE country_code = v_cc AND service_type = p_service_type AND plan_code = p_plan
    AND billing_cycle = COALESCE(p_cycle,'monthly') AND is_active = true
  LIMIT 1;
  IF v_row.id IS NULL THEN
    RETURN jsonb_build_object('found', false, 'reason', 'NO_GRID_PRICE', 'country_code', v_cc);
  END IF;

  SELECT flag_emoji, currency_symbol INTO v_flag, v_sym FROM public.countries WHERE country_code = v_cc;

  RETURN jsonb_build_object(
    'found', true, 'country_code', v_cc, 'service_type', p_service_type, 'plan_code', p_plan,
    'price', v_row.price, 'currency_code', v_row.currency_code, 'currency_symbol', v_sym,
    'commission_rate', v_row.commission_rate, 'billing_cycle', v_row.billing_cycle, 'flag_emoji', v_flag
  );
END;
$$;
REVOKE EXECUTE ON FUNCTION public.get_subscription_price_by_country(uuid, text, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_subscription_price_by_country(uuid, text, text, text) TO authenticated, service_role;

-- 6) ── RPC ADMIN : poser/modifier un prix par pays (atomique, gardé) ────────
CREATE OR REPLACE FUNCTION public.admin_set_subscription_price(
  p_country_code text, p_service_type text, p_plan_code text, p_price numeric,
  p_commission_rate numeric DEFAULT NULL, p_cycle text DEFAULT 'monthly', p_is_active boolean DEFAULT true
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_cur text;
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'NOT_ADMIN'; END IF;
  IF p_price IS NULL OR p_price < 0 THEN RAISE EXCEPTION 'INVALID_PRICE'; END IF;

  SELECT currency_code INTO v_cur FROM public.countries WHERE country_code = p_country_code AND is_active = true;
  IF v_cur IS NULL THEN RAISE EXCEPTION 'COUNTRY_NOT_FOUND_OR_INACTIVE'; END IF;

  INSERT INTO public.subscription_prices (country_code, service_type, plan_code, price, currency_code, commission_rate, billing_cycle, is_active)
  VALUES (p_country_code, p_service_type, p_plan_code, p_price, v_cur, COALESCE(p_commission_rate,0), COALESCE(p_cycle,'monthly'), COALESCE(p_is_active,true))
  ON CONFLICT (country_code, service_type, plan_code, billing_cycle) DO UPDATE
    SET price = EXCLUDED.price, currency_code = EXCLUDED.currency_code,
        commission_rate = COALESCE(p_commission_rate, public.subscription_prices.commission_rate),
        is_active = EXCLUDED.is_active, updated_at = now();

  RETURN jsonb_build_object('success', true, 'country_code', p_country_code, 'currency_code', v_cur, 'price', p_price);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.admin_set_subscription_price(text, text, text, numeric, numeric, text, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.admin_set_subscription_price(text, text, text, numeric, numeric, text, boolean) TO authenticated, service_role;

-- 7) ── RPC ADMIN : activer/désactiver un pays ───────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_set_country_active(
  p_country_code text, p_is_active boolean
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'NOT_ADMIN'; END IF;
  UPDATE public.countries SET is_active = p_is_active, updated_at = now() WHERE country_code = p_country_code;
  IF NOT FOUND THEN RAISE EXCEPTION 'COUNTRY_NOT_FOUND'; END IF;
  RETURN jsonb_build_object('success', true, 'country_code', p_country_code, 'is_active', p_is_active);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.admin_set_country_active(text, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.admin_set_country_active(text, boolean) TO authenticated, service_role;

-- 8) ── RPC ADMIN : changer le pays d'un utilisateur (motif OBLIGATOIRE + log) ─
CREATE OR REPLACE FUNCTION public.admin_change_user_country(
  p_user_id uuid, p_new_country text, p_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_old text;
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'NOT_ADMIN'; END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) < 3 THEN RAISE EXCEPTION 'REASON_REQUIRED'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.countries WHERE country_code = p_new_country AND is_active = true) THEN
    RAISE EXCEPTION 'COUNTRY_NOT_FOUND_OR_INACTIVE';
  END IF;

  SELECT country_code INTO v_old FROM public.profiles WHERE id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'USER_NOT_FOUND'; END IF;

  UPDATE public.profiles SET country_code = p_new_country, country_locked = true, updated_at = now()
  WHERE id = p_user_id;

  INSERT INTO public.user_country_change_log (user_id, old_country, new_country, reason, changed_by)
  VALUES (p_user_id, v_old, p_new_country, p_reason, auth.uid());

  RETURN jsonb_build_object('success', true, 'old_country', v_old, 'new_country', p_new_country);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.admin_change_user_country(uuid, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.admin_change_user_country(uuid, text, text) TO authenticated, service_role;

-- 9) ── RLS : lecture pays = tous (auth) ; grille = uniquement SON pays ───────
ALTER TABLE public.countries            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscription_prices  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_country_change_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS countries_read ON public.countries;
CREATE POLICY countries_read ON public.countries FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS countries_admin_write ON public.countries;
CREATE POLICY countries_admin_write ON public.countries FOR ALL TO authenticated
  USING (public.is_admin_or_pdg()) WITH CHECK (public.is_admin_or_pdg());

-- Le client ne voit QUE la grille de SON pays verrouillé (jamais les autres pays).
DROP POLICY IF EXISTS subprices_read_own_country ON public.subscription_prices;
CREATE POLICY subprices_read_own_country ON public.subscription_prices FOR SELECT TO authenticated
  USING (
    public.is_admin_or_pdg()
    OR country_code = (SELECT country_code FROM public.profiles WHERE id = auth.uid())
  );

DROP POLICY IF EXISTS subprices_admin_write ON public.subscription_prices;
CREATE POLICY subprices_admin_write ON public.subscription_prices FOR ALL TO authenticated
  USING (public.is_admin_or_pdg()) WITH CHECK (public.is_admin_or_pdg());

DROP POLICY IF EXISTS country_log_admin ON public.user_country_change_log;
CREATE POLICY country_log_admin ON public.user_country_change_log FOR SELECT TO authenticated
  USING (public.is_admin_or_pdg());

SELECT 'Fondation prix par pays posée : countries (7) + subscription_prices (grille) + profiles.country_code/locked + résolveur + 3 RPC admin + RLS.' AS status;
