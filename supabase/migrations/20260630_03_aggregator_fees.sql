-- ════════════════════════════════════════════════════════════════════════════
-- ÉTAPE 2 — FRAIS AGRÉGATEUR par méthode + décomposition montant → NET → commission.
-- ════════════════════════════════════════════════════════════════════════════
-- La commission plateforme (le 1%) doit être calculée sur le NET (après les frais
-- réels de Stripe / Orange-MTN via ChapChapPay), pas sur le brut — sinon, comme
-- 1% < 2-3% de frais agrégateur, la plateforme PERD à chaque vente.
--
-- ⚠️ Taux par DÉFAUT (configurables par le PDG dans pdg_settings) — À AJUSTER avec
-- les vrais taux contractuels. bearer = qui porte les frais (reco 'customer' :
-- JAMAIS 'platform' tant que la commission < frais agrégateur).
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

-- Réglages (format {"value": X}, comme tous les pdg_settings — lus par pdg_setting_numeric).
INSERT INTO public.pdg_settings (setting_key, setting_value) VALUES
  ('aggregator_fee_card',         '{"value": 2.9}'::jsonb),   -- Stripe (carte) — METTRE le taux réel
  ('aggregator_fee_orange',       '{"value": 2.0}'::jsonb),   -- Orange via ChapChapPay
  ('aggregator_fee_mtn',          '{"value": 2.0}'::jsonb),   -- MTN via ChapChapPay
  ('aggregator_fee_mobile_money', '{"value": 2.0}'::jsonb),   -- mobile money générique
  ('aggregator_fee_om',           '{"value": 2.0}'::jsonb),   -- alias Orange Money ('OM')
  ('aggregator_fee_wallet',       '{"value": 0.0}'::jsonb),   -- interne 224, pas de frais
  ('aggregator_fee_cash',         '{"value": 0.0}'::jsonb),   -- espèces, pas d'agrégateur
  ('aggregator_fee_bearer',       '{"value": "customer"}'::jsonb)  -- customer | seller | platform
ON CONFLICT (setting_key) DO NOTHING;

-- Taux de frais agrégateur (%) pour une méthode de paiement. Repli sur mobile_money
-- puis 0 si la clé n'existe pas.
CREATE OR REPLACE FUNCTION public.get_aggregator_fee_rate(p_method text)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(
    (SELECT (setting_value->>'value')::numeric FROM public.pdg_settings
     WHERE setting_key = 'aggregator_fee_' || lower(coalesce(p_method, ''))),
    (SELECT (setting_value->>'value')::numeric FROM public.pdg_settings
     WHERE setting_key = 'aggregator_fee_mobile_money'),
    0
  );
$$;
REVOKE ALL ON FUNCTION public.get_aggregator_fee_rate(text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_aggregator_fee_rate(text) TO authenticated, service_role;

-- Décomposition d'un paiement : brut → frais agrégateur → net → commission plateforme
-- (calculée SUR LE NET). platform_fee = LA BASE de la commission agent (Étapes 3-4).
CREATE OR REPLACE FUNCTION public.compute_payment_breakdown(
  p_gross numeric,
  p_method text,
  p_platform_fee_rate numeric DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_agg_rate  numeric := public.get_aggregator_fee_rate(p_method);
  v_agg_fee   numeric;
  v_net       numeric;
  v_plat_rate numeric := COALESCE(p_platform_fee_rate, public.pdg_setting_numeric('purchase_commission_percent', 1));
  v_plat_fee  numeric;
BEGIN
  IF p_gross IS NULL OR p_gross <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'MONTANT_INVALIDE');
  END IF;
  v_agg_rate  := GREATEST(0, COALESCE(v_agg_rate, 0));
  v_plat_rate := GREATEST(0, COALESCE(v_plat_rate, 0));
  v_agg_fee   := ROUND(p_gross * v_agg_rate / 100, 2);     -- frais agrégateur réels
  v_net       := ROUND(p_gross - v_agg_fee, 2);            -- net après agrégateur
  v_plat_fee  := ROUND(v_net * v_plat_rate / 100, 2);      -- commission plateforme SUR LE NET
  RETURN jsonb_build_object(
    'success', true,
    'gross', p_gross,
    'aggregator_rate', v_agg_rate,
    'aggregator_fee', v_agg_fee,
    'net', v_net,
    'platform_fee_rate', v_plat_rate,
    'platform_fee', v_plat_fee
  );
END;
$$;
REVOKE ALL ON FUNCTION public.compute_payment_breakdown(numeric, text, numeric) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.compute_payment_breakdown(numeric, text, numeric) TO authenticated, service_role;

DO $$ BEGIN
  RAISE NOTICE '✅ frais agrégateur + compute_payment_breakdown OK (taux par défaut, à ajuster dans pdg_settings)';
END $$;

COMMIT;
