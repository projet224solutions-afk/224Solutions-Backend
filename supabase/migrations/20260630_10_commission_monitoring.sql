-- ════════════════════════════════════════════════════════════════════════════
-- ÉTAPE 10 — SURVEILLANCE COMMISSION (LECTURE SEULE, n'altère aucun solde).
-- ════════════════════════════════════════════════════════════════════════════
-- Contrôle de CONSERVATION : ce qui SORT du PDG (platform_revenue payout, écrit par
-- l'étape 9) doit égaler ce qui ENTRE chez les agents (agent_commissions_log validé).
-- Un écart = mint résiduel / fuite → à investiguer.
--   • Les vieilles commissions (avant le fix du mint, 20260630_01) n'ont PAS de ligne
--     payout → la conservation les révélera (versé agents > débité PDG) : c'est
--     VOULU (chiffrer la dette du mint passé).
--   • Aucune écriture : vues + RPC STABLE. Accès financier réservé (service_role /
--     PDG via RPC gaté par rôle).
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ── 2.4 — Idempotence : réaffirme l'index unique EXISTANT (agent_id, transaction_id).
-- (Plus STRICT que (agent_id, transaction_id, source_type) : une seule commission par
--  agent et par transaction, quelle qu'en soit la source. On NE l'affaiblit pas.)
CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_commissions_log_unique_transaction
  ON public.agent_commissions_log (agent_id, transaction_id)
  WHERE transaction_id IS NOT NULL;

-- ── 3.1 — Vue de réconciliation (entre = sort ?), par jour.
-- CTE + FULL OUTER JOIN : agrège les deux côtés par jour puis les compare (évite la
-- sous-requête corrélée sur une colonne non-groupée).
CREATE OR REPLACE VIEW public.commission_reconciliation AS
WITH agents AS (
  SELECT date_trunc('day', created_at) AS jour,
         count(*)                      AS nb_commissions,
         COALESCE(sum(amount), 0)      AS total_verse_agents
  FROM public.agent_commissions_log
  WHERE status = 'validated'
  GROUP BY 1
),
pdg AS (
  SELECT date_trunc('day', created_at) AS jour,
         COALESCE(sum(-amount), 0)     AS total_debite_pdg
  FROM public.platform_revenue
  WHERE revenue_type = 'agent_commission_payout'
  GROUP BY 1
)
SELECT
  COALESCE(a.jour, p.jour)                                          AS jour,
  COALESCE(a.nb_commissions, 0)                                     AS nb_commissions,
  COALESCE(a.total_verse_agents, 0)                                 AS total_verse_agents,
  COALESCE(p.total_debite_pdg, 0)                                   AS total_debite_pdg,
  COALESCE(a.total_verse_agents, 0) - COALESCE(p.total_debite_pdg, 0) AS ecart
FROM agents a
FULL OUTER JOIN pdg p ON a.jour = p.jour
ORDER BY 1 DESC;

COMMENT ON VIEW public.commission_reconciliation IS
  'Conservation par jour : total_verse_agents doit ≈ total_debite_pdg. Un écart = mint/fuite.';

-- ── 3.3 — Tableau de bord financier PDG (revenus / sorties / net) par jour.
CREATE OR REPLACE VIEW public.pdg_financial_dashboard AS
SELECT
  date_trunc('day', created_at)                       AS jour,
  sum(CASE WHEN amount > 0 THEN amount ELSE 0 END)    AS revenus_bruts,   -- entrées (commissions encaissées)
  sum(CASE WHEN amount < 0 THEN -amount ELSE 0 END)   AS sorties,         -- sorties (payouts agents, etc.)
  sum(amount)                                         AS revenu_net       -- ce que le PDG garde
FROM public.platform_revenue
GROUP BY date_trunc('day', created_at)
ORDER BY 1 DESC;

COMMENT ON VIEW public.pdg_financial_dashboard IS
  'Agrégat platform_revenue par jour : entrées (+), sorties (-), net. Lecture backend (service_role).';

-- Accès financier restreint : le backend (service_role) lit et sert au PDG après
-- contrôle de rôle. Pas d'exposition directe aux clients.
REVOKE ALL ON public.commission_reconciliation FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.pdg_financial_dashboard   FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.commission_reconciliation TO service_role;
GRANT SELECT ON public.pdg_financial_dashboard   TO service_role;

-- ── 3.2 — RPC de contrôle de conservation (lecture, gaté PDG).
CREATE OR REPLACE FUNCTION public.check_commission_conservation(p_days int DEFAULT 7)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_agents  numeric;
  v_pdg_out numeric;
  v_ecart   numeric;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND lower(role::text) IN ('pdg', 'ceo', 'admin')
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NON_AUTORISE');
  END IF;

  SELECT COALESCE(sum(amount), 0) INTO v_agents
  FROM public.agent_commissions_log
  WHERE status = 'validated' AND created_at > now() - (p_days || ' days')::interval;

  SELECT COALESCE(sum(-amount), 0) INTO v_pdg_out
  FROM public.platform_revenue
  WHERE revenue_type = 'agent_commission_payout'
    AND created_at > now() - (p_days || ' days')::interval;

  v_ecart := v_agents - v_pdg_out;
  RETURN jsonb_build_object(
    'success', true,
    'period_days', p_days,
    'total_verse_agents', v_agents,
    'total_debite_pdg', v_pdg_out,
    'ecart', v_ecart,
    'conservation_ok', (abs(v_ecart) < 1)   -- tolérance arrondi
  );
END;
$$;

REVOKE ALL ON FUNCTION public.check_commission_conservation(int) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.check_commission_conservation(int) TO authenticated, service_role;

DO $$ BEGIN
  RAISE NOTICE '✅ Surveillance commission : réconciliation + dashboard PDG + check_commission_conservation';
END $$;

COMMIT;
