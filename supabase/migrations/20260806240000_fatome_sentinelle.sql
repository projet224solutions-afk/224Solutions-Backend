-- ═══════════════════════════════════════════════════════════════════════════
-- 👻 FATOME SENTINELLE — auto-surveillance TEMPS RÉEL des mouvements d'argent.
-- ÉTAGE A : détection instantanée par triggers LÉGERS (ligne seule, jamais de scan),
-- non-bloquants (EXCEPTION WHEN OTHERS → jamais de RAISE qui casse la transaction métier).
-- Anomalie → table append-only `fatome_anomalies` (dédup (type, ref)) + notification PDG.
-- Migration NOUVELLE.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.fatome_anomalies (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  anomaly_type text NOT NULL,
  ref text NOT NULL,                 -- référence de l'op (parent_tx_id, tx id…)
  severity text NOT NULL DEFAULT 'high' CHECK (severity IN ('low','medium','high','critical')),
  detail jsonb,
  resolved boolean NOT NULL DEFAULT false,
  detected_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (anomaly_type, ref)         -- une anomalie = une ligne (anti-spam)
);
ALTER TABLE public.fatome_anomalies ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS fatome_anom_read_pdg ON public.fatome_anomalies;
CREATE POLICY fatome_anom_read_pdg ON public.fatome_anomalies FOR SELECT TO authenticated
  USING (public.is_admin_or_pdg());
-- Écriture : fonctions SECURITY DEFINER only (aucune policy INSERT).

-- Émet une anomalie (idempotent par (type, ref)) + notifie le PDG en temps réel. Best-effort.
CREATE OR REPLACE FUNCTION public.fatome_raise(p_type text, p_ref text, p_severity text, p_detail jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_new boolean := false; p record;
BEGIN
  INSERT INTO public.fatome_anomalies (anomaly_type, ref, severity, detail)
  VALUES (p_type, p_ref, coalesce(p_severity,'high'), p_detail)
  ON CONFLICT (anomaly_type, ref) DO NOTHING;
  GET DIAGNOSTICS v_new = ROW_COUNT;
  IF v_new THEN
    -- Notification PDG (cloche existante) — une seule fois (dédup ci-dessus).
    FOR p IN SELECT id FROM public.profiles WHERE role IN ('pdg','admin','ceo') LIMIT 5 LOOP
      BEGIN
        INSERT INTO public.notifications (user_id, title, message, type, metadata)
        VALUES (p.id, '👻 Fatome Sentinelle : anomalie détectée',
          p_type || ' — réf ' || p_ref, 'fatome_anomaly',
          jsonb_build_object('anomaly_type', p_type, 'ref', p_ref, 'link', '/pdg'));
      EXCEPTION WHEN OTHERS THEN NULL; END;
    END LOOP;
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.fatome_raise(text, text, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fatome_raise(text, text, text, jsonb) TO service_role;

-- ── TRIGGER léger sur agent_cash_operations (AFTER INSERT) ──────────────────
-- L'op est insérée APRÈS les jambes ledger → on peut lire la devise client. Anomalie :
-- montant > 0, règle de commission > 0, part agent = 0, devise à DÉCIMALES (le bug EUR/USD/SLE).
-- Comparaisons locales + 2 petits lookups indexés → coût par ligne négligeable. JAMAIS bloquant.
CREATE OR REPLACE FUNCTION public.fatome_check_agent_cash()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_cur text; v_rules jsonb; v_pct numeric;
BEGIN
  IF NEW.operation IN ('deposit','withdrawal') AND NEW.amount > 0 AND coalesce(NEW.agent_share,0) = 0 THEN
    SELECT l.currency INTO v_cur FROM public.agent_cash_ledger l
      WHERE l.parent_tx_id = NEW.parent_tx_id AND l.leg = 'client_credit' LIMIT 1;
    IF v_cur IS NOT NULL AND public._ccy_decimals(v_cur) > 0 THEN
      v_rules := public._acash_currency_rules(v_cur);
      v_pct := (v_rules->>(CASE WHEN NEW.operation='deposit' THEN 'w_pct' ELSE 'w_pct' END))::numeric;
      IF coalesce(v_pct,0) > 0 THEN
        PERFORM public.fatome_raise('commission_zero_decimal', NEW.parent_tx_id::text, 'high',
          jsonb_build_object('operation', NEW.operation, 'amount', NEW.amount, 'currency', v_cur,
            'agent_share', NEW.agent_share, 'pct', v_pct));
      END IF;
    END IF;
  END IF;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RETURN NULL; -- ne JAMAIS casser la transaction métier
END;
$$;
DROP TRIGGER IF EXISTS trg_fatome_agent_cash ON public.agent_cash_operations;
CREATE TRIGGER trg_fatome_agent_cash
  AFTER INSERT ON public.agent_cash_operations
  FOR EACH ROW EXECUTE FUNCTION public.fatome_check_agent_cash();

-- ── Lecture pour la carte PDG : anomalies 24 h par type ─────────────────────
CREATE OR REPLACE FUNCTION public.fatome_anomalies_report(p_since timestamptz DEFAULT now() - interval '24 hours')
RETURNS TABLE(anomaly_type text, severity text, total bigint, unresolved bigint, last_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;
  RETURN QUERY
  SELECT a.anomaly_type, max(a.severity), count(*), count(*) FILTER (WHERE NOT a.resolved), max(a.detected_at)
  FROM public.fatome_anomalies a WHERE a.detected_at >= p_since
  GROUP BY a.anomaly_type ORDER BY 3 DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.fatome_anomalies_report(timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fatome_anomalies_report(timestamptz) TO authenticated, service_role;
