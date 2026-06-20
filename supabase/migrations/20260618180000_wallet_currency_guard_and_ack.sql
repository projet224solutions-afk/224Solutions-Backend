-- ============================================================================
-- 🛡️ (2) PRÉVENTION : un nouveau wallet adopte la DEVISE DU PAYS de l'utilisateur.
-- 🧹 (3) NETTOYAGE : acquitter les anomalies argent HISTORIQUES (pré-correctifs) pour que
--        le watchdog ne signale plus que les NOUVELLES (vraies) anomalies.
-- ----------------------------------------------------------------------------
-- (2) Trigger BEFORE INSERT sur wallets : force currency = countries.currency_code du
--     country_code du profil (repli GNF). Ferme la cause racine du « wallet EUR pour un
--     Guinéen » → plus jamais de wallet en désaccord avec le pays, quel que soit le code appelant.
-- (3) Table `money_integrity_acknowledged` : refs d'anomalies acquittées. Le watchdog les
--     EXCLUT. On y verse les 9 escrows sans commission + 6 libérations créditées à 0 (toutes
--     pré-correctifs ; wallet 71 a été ré-crédité au reset). Réversible (DELETE pour ré-alerter).
-- ============================================================================

-- ── (2) Trigger : devise du wallet = devise du pays à la création ────────────
CREATE OR REPLACE FUNCTION public.wallet_set_country_currency()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_cur text;
BEGIN
  SELECT c.currency_code INTO v_cur
  FROM public.profiles p
  JOIN public.countries c ON c.country_code = p.country_code
  WHERE p.id = NEW.user_id;

  IF v_cur IS NOT NULL AND v_cur <> '' THEN
    NEW.currency := upper(v_cur);          -- aligne sur le pays verrouillé
  ELSIF NEW.currency IS NULL THEN
    NEW.currency := 'GNF';                 -- repli plateforme si pays inconnu
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_wallet_country_currency ON public.wallets;
CREATE TRIGGER trg_wallet_country_currency
  BEFORE INSERT ON public.wallets
  FOR EACH ROW EXECUTE FUNCTION public.wallet_set_country_currency();

-- ── (3) Table d'acquittement des anomalies argent ───────────────────────────
CREATE TABLE IF NOT EXISTS public.money_integrity_acknowledged (
  check_key       text NOT NULL,
  ref_id          text NOT NULL,
  reason          text,
  acknowledged_by uuid,
  acknowledged_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (check_key, ref_id)
);
ALTER TABLE public.money_integrity_acknowledged ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS mia_admin ON public.money_integrity_acknowledged;
CREATE POLICY mia_admin ON public.money_integrity_acknowledged FOR ALL TO authenticated
  USING (public.is_admin_or_pdg()) WITH CHECK (public.is_admin_or_pdg());

-- Acquitter les 9 escrows libérés SANS commission (pré-correctif, vendeur déjà payé à 100%).
INSERT INTO public.money_integrity_acknowledged (check_key, ref_id, reason)
SELECT 'escrow_released_no_commission', e.id::text, 'Historique pré-correctif commission tous-moyens (20260618)'
FROM public.escrow_transactions e
JOIN public.orders o ON o.id = e.order_id
WHERE e.status = 'released' AND COALESCE(e.commission_amount, 0) = 0
ON CONFLICT (check_key, ref_id) DO NOTHING;

-- Acquitter les 6 libérations créditées à 0 (wallet 71 quarantine → ré-crédité au reset).
INSERT INTO public.money_integrity_acknowledged (check_key, ref_id, reason)
SELECT 'escrow_released_zero_credit', wt.id::text, 'Historique pré-correctif (solde gonflé/quarantine, ré-crédité au reset wallet)'
FROM public.wallet_transactions wt
WHERE wt.transaction_type = 'escrow_release' AND COALESCE((wt.metadata->>'credited')::numeric, 0) = 0
ON CONFLICT (check_key, ref_id) DO NOTHING;

-- ── Watchdog : exclut les anomalies acquittées (ne signale plus que les NOUVELLES) ──
CREATE OR REPLACE FUNCTION public.money_integrity_report()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_dup int; v_fx int; v_noc int; v_zc int;
BEGIN
  SELECT count(*) INTO v_dup FROM (
    SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname ~* '(credit_user_wallet_safe|create_order_core|release_escrow_to_seller|execute_atomic_wallet_transfer|refund_order_escrow|purchase_.*_subscription|create_pos_sale_complete)'
    GROUP BY p.proname HAVING count(*) > 1
  ) d;

  SELECT CASE WHEN EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'credit_user_wallet_safe'
      AND pg_get_functiondef(p.oid) LIKE '%FX_RATE_MISSING%'
  ) THEN 0 ELSE 1 END INTO v_fx;

  -- Escrows libérés sans commission, NON acquittés.
  SELECT count(*) INTO v_noc
  FROM public.escrow_transactions e JOIN public.orders o ON o.id = e.order_id
  WHERE e.status = 'released' AND COALESCE(e.commission_amount, 0) = 0
    AND NOT EXISTS (SELECT 1 FROM public.money_integrity_acknowledged a
                    WHERE a.check_key = 'escrow_released_no_commission' AND a.ref_id = e.id::text);

  -- Libérations créditées à 0, NON acquittées.
  SELECT count(*) INTO v_zc
  FROM public.wallet_transactions wt
  WHERE wt.transaction_type = 'escrow_release'
    AND COALESCE((wt.metadata->>'credited')::numeric, 0) = 0
    AND NOT EXISTS (SELECT 1 FROM public.money_integrity_acknowledged a
                    WHERE a.check_key = 'escrow_released_zero_credit' AND a.ref_id = wt.id::text);

  RETURN jsonb_build_object(
    'generated_at', now(),
    'checks', jsonb_build_array(
      jsonb_build_object('key','money_duplicate_overload','label','Surcharges de fonctions argent en double (drift)','severity','critical','count',v_dup,'observed',v_dup),
      jsonb_build_object('key','credit_fx_not_converting','label','credit_user_wallet_safe sans conversion de devise','severity','critical','count',v_fx,'observed',v_fx),
      jsonb_build_object('key','escrow_released_no_commission','label','Escrows libérés sans commission prélevée','severity','critical','count',v_noc,'observed',v_noc),
      jsonb_build_object('key','escrow_released_zero_credit','label','Libérations escrow créditées à 0 (vendeur non payé / quarantaine)','severity','warning','count',v_zc,'observed',v_zc)
    )
  );
END;
$$;
REVOKE ALL ON FUNCTION public.money_integrity_report() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.money_integrity_report() TO authenticated, service_role;

SELECT 'Prévention devise (trigger wallets) + acquittement anomalies historiques (watchdog ne signale plus que les nouvelles).' AS status;
