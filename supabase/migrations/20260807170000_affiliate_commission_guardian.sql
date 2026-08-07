-- ═══════════════════════════════════════════════════════════════════════════
-- CHANTIER 2 — Gardien de la chaîne commissions d'affiliation + file d'ATTENTE.
-- La commission d'affiliation n'est JAMAIS perdue : quand elle ne peut être versée
-- (taux indisponible / Fatome en panne), elle passe en ATTENTE (affiliate_commission_pending)
-- au lieu d'être ignorée EN SILENCE. Un job leader-gardé la verse dès qu'un taux frais existe
-- (conversion tracée via _acash_fx : rate + date + source ; garde de fraîcheur 24 h).
-- Gardien affiliate_commission_monitor_report → registre MONITOR_DOMAINS → étage B Fatome (badge affiliation).
-- Migration NOUVELLE. Aucun flux d'argent existant modifié — le pending REMPLACE le silence.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.affiliate_commission_pending (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_type text NOT NULL,                 -- 'achat_produit' | 'abonnement' | ...
  source_ref text NOT NULL,                  -- order_id / subscription_id / tx id (idempotence)
  beneficiary_user_id uuid NOT NULL,         -- user dont l'agent touche (ex. vendor.user_id)
  fee_amount numeric NOT NULL CHECK (fee_amount > 0),
  fee_currency text NOT NULL,
  reason text NOT NULL DEFAULT 'NO_RATE' CHECK (reason IN ('NO_RATE','FX_DOWN')),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','resolved','cancelled')),
  attempts int NOT NULL DEFAULT 0,
  last_attempt_at timestamptz,
  last_error text,
  detail jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz,
  UNIQUE (source_type, source_ref)           -- une opération = une ligne (idempotence)
);
CREATE INDEX IF NOT EXISTS idx_affiliate_pending_status ON public.affiliate_commission_pending(status, created_at);
ALTER TABLE public.affiliate_commission_pending ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS affiliate_pending_read_pdg ON public.affiliate_commission_pending;
CREATE POLICY affiliate_pending_read_pdg ON public.affiliate_commission_pending FOR SELECT TO authenticated
  USING (public.is_admin_or_pdg());
-- Écriture : RPC SECURITY DEFINER only (aucune policy INSERT/UPDATE).

-- Mise en ATTENTE (idempotent par (source_type, source_ref)). service_role only.
CREATE OR REPLACE FUNCTION public.affiliate_commission_enqueue(
  p_source_type text, p_source_ref text, p_beneficiary uuid,
  p_fee_amount numeric, p_fee_currency text, p_reason text DEFAULT 'NO_RATE', p_detail jsonb DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $func$
BEGIN
  IF p_fee_amount IS NULL OR p_fee_amount <= 0 OR p_beneficiary IS NULL
     OR p_source_ref IS NULL OR p_source_type IS NULL THEN RETURN; END IF;
  INSERT INTO public.affiliate_commission_pending
    (source_type, source_ref, beneficiary_user_id, fee_amount, fee_currency, reason, detail)
  VALUES (p_source_type, p_source_ref, p_beneficiary, p_fee_amount, upper(coalesce(p_fee_currency,'GNF')),
    COALESCE(p_reason,'NO_RATE'), p_detail)
  ON CONFLICT (source_type, source_ref) DO NOTHING;
END;
$func$;
REVOKE ALL ON FUNCTION public.affiliate_commission_enqueue(text,text,uuid,numeric,text,text,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.affiliate_commission_enqueue(text,text,uuid,numeric,text,text,jsonb) TO service_role;

-- Liste des pending à retenter (job leader-gardé). service_role only.
CREATE OR REPLACE FUNCTION public.affiliate_commission_pending_list(p_limit int DEFAULT 50)
RETURNS TABLE(id uuid, source_type text, source_ref text, beneficiary_user_id uuid, fee_amount numeric, fee_currency text, attempts int)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $func$
  SELECT id, source_type, source_ref, beneficiary_user_id, fee_amount, fee_currency, attempts
  FROM public.affiliate_commission_pending WHERE status = 'pending'
  ORDER BY created_at ASC LIMIT GREATEST(1, LEAST(coalesce(p_limit,50), 500));
$func$;
REVOKE ALL ON FUNCTION public.affiliate_commission_pending_list(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.affiliate_commission_pending_list(int) TO service_role;

-- Marque le résultat d'une tentative (resolved / cancelled / reste pending). service_role only.
CREATE OR REPLACE FUNCTION public.affiliate_commission_pending_mark(
  p_id uuid, p_status text, p_error text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $func$
BEGIN
  UPDATE public.affiliate_commission_pending
  SET status   = CASE WHEN p_status IN ('resolved','cancelled') THEN p_status ELSE status END,
      attempts = attempts + 1,
      last_attempt_at = now(),
      last_error = p_error,
      resolved_at = CASE WHEN p_status = 'resolved' THEN now() ELSE resolved_at END
  WHERE id = p_id;
END;
$func$;
REVOKE ALL ON FUNCTION public.affiliate_commission_pending_mark(uuid,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.affiliate_commission_pending_mark(uuid,text,text) TO service_role;

-- 🛡️ GARDIEN — format monitor standard { generated_at, checks:[...] }. service_role only.
-- Fenêtre 7 j. Alimente le registre MONITOR_DOMAINS → system_alerts + étage B Fatome.
CREATE OR REPLACE FUNCTION public.affiliate_commission_monitor_report()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $func$
DECLARE v_gap int; v_split int; v_pending int; v_cap numeric;
BEGIN
  v_cap := public.pdg_setting_numeric('max_total_agent_commission_percentage', 100);

  -- affiliate_gap : commande PAYÉE (7 j), frais acheteur > 0, vendeur rattaché à un agent ACTIF,
  -- MAIS aucune commission tracée dans agent_commissions_log ET pas en file d'attente (ce n'est pas un
  -- gap si c'est déjà en attente). = commission d'affiliation perdue.
  SELECT count(*) INTO v_gap
  FROM public.orders o
  JOIN public.vendors v ON v.id = o.vendor_id
  WHERE o.payment_status = 'paid'
    AND o.created_at >= now() - interval '7 days'
    AND COALESCE(o.platform_fee_amount, 0) > 0
    AND EXISTS (SELECT 1 FROM public.get_user_agent(v.user_id) ga WHERE ga.agent_id IS NOT NULL)
    AND NOT EXISTS (SELECT 1 FROM public.agent_commissions_log l
                    WHERE l.transaction_id = o.id AND l.source_type = 'achat_produit')
    AND NOT EXISTS (SELECT 1 FROM public.affiliate_commission_pending p
                    WHERE p.source_type = 'achat_produit' AND p.source_ref = o.id::text AND p.status = 'pending');

  -- affiliate_split_invalid : par transaction, somme des parts (sous-agent + parent) > plafond des frais.
  SELECT count(*) INTO v_split FROM (
    SELECT l.transaction_id, max(l.transaction_amount) AS fee, sum(l.amount) AS parts
    FROM public.agent_commissions_log l
    WHERE l.created_at >= now() - interval '7 days'
      AND l.source_type IN ('achat_produit','abonnement')
    GROUP BY l.transaction_id
  ) g WHERE g.fee > 0 AND g.parts > g.fee * v_cap / 100.0;

  -- affiliate_pending_overdue : commissions en attente depuis > 24 h (taux jamais revenu / Fatome KO).
  SELECT count(*) INTO v_pending FROM public.affiliate_commission_pending
  WHERE status = 'pending' AND created_at < now() - interval '24 hours';

  RETURN jsonb_build_object(
    'generated_at', now(),
    'checks', jsonb_build_array(
      jsonb_build_object('key','affiliate_gap','label','Commission affiliation manquante (commande payée, vendeur à agent actif)','severity','high','count',v_gap,'observed',v_gap),
      jsonb_build_object('key','affiliate_split_invalid','label','Répartition affiliation > plafond des frais','severity','critical','count',v_split,'observed',v_split),
      jsonb_build_object('key','affiliate_pending_overdue','label','Commission affiliation en attente > 24 h','severity','high','count',v_pending,'observed',v_pending)
    ));
END;
$func$;
REVOKE ALL ON FUNCTION public.affiliate_commission_monitor_report() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.affiliate_commission_monitor_report() TO service_role;
