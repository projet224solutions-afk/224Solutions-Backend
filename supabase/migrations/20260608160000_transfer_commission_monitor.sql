-- 🩺 SURVEILLANCE TRANSFERTS + COMMISSIONS — RPC de détection d'anomalies (lecture seule)
-- Même format que les autres domaines. À ajouter à MONITOR_DOMAINS côté backend.

-- ───────────────────────── TRANSFERTS (P2P / internationaux) ─────────────────────────
CREATE OR REPLACE FUNCTION public.transfer_monitor_report()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_stuck   int;
  v_orphan  int;
  v_nonpos  int;
  v_rapid   int;
BEGIN
  -- Transfert sortant bloqué 'pending' depuis > 1h (argent en limbo). status casté en texte (anti-enum).
  SELECT count(*) INTO v_stuck FROM public.wallet_transactions
  WHERE transaction_type::text IN ('transfer_out','international_transfer','withdrawal','mobile_money_out')
    AND status::text = 'pending' AND created_at < now() - interval '1 hour';

  -- Transfert sortant sans destinataire (orphelin)
  SELECT count(*) INTO v_orphan FROM public.wallet_transactions
  WHERE transaction_type = 'transfer_out' AND created_at > now() - interval '7 days'
    AND receiver_user_id IS NULL AND receiver_wallet_id IS NULL;

  -- Montant nul ou négatif
  SELECT count(*) INTO v_nonpos FROM public.wallet_transactions
  WHERE transaction_type::text IN ('transfer_out','transfer_in','international_transfer')
    AND COALESCE(amount, 0) <= 0 AND created_at > now() - interval '7 days';

  -- Transferts en rafale (5 min) — possible attaque / blanchiment
  SELECT count(*) INTO v_rapid FROM public.wallet_transactions
  WHERE transaction_type::text IN ('transfer_out','international_transfer')
    AND created_at > now() - interval '5 minutes';

  RETURN jsonb_build_object('generated_at', now(), 'checks', jsonb_build_array(
    jsonb_build_object('key','transfer_stuck','label','Transfert sortant bloqué en attente > 1h','severity','high','count',v_stuck,'observed',v_stuck),
    jsonb_build_object('key','transfer_orphan','label','Transfert sortant sans destinataire','severity','medium','count',v_orphan,'observed',v_orphan),
    jsonb_build_object('key','transfer_nonpositive','label','Transfert au montant nul ou négatif','severity','medium','count',v_nonpos,'observed',v_nonpos),
    jsonb_build_object('key','transfer_rapid','label','Transferts en rafale (5 min) — possible attaque/blanchiment','severity',CASE WHEN v_rapid > 30 THEN 'high' ELSE 'low' END,'count',CASE WHEN v_rapid > 30 THEN v_rapid ELSE 0 END,'observed',v_rapid)
  ));
END;
$$;

REVOKE ALL ON FUNCTION public.transfer_monitor_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.transfer_monitor_report() TO service_role;

-- ───────────────────────── COMMISSIONS (agents / PDG) ─────────────────────────
CREATE OR REPLACE FUNCTION public.commission_monitor_report()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_gap     int;
  v_badrate int;
  v_nonpos  int;
BEGIN
  -- Commission acheteur prélevée (wallet) mais NON enregistrée dans revenus_pdg (incohérence revenus PDG)
  SELECT count(*) INTO v_gap FROM public.wallet_transactions wt
  WHERE wt.transaction_type = 'commission'
    AND wt.metadata->>'source' = 'buyer_commission'
    AND wt.created_at > now() - interval '7 days'
    AND wt.metadata->>'order_id' IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM public.revenus_pdg r WHERE r.metadata->>'order_id' = wt.metadata->>'order_id');

  -- Taux de commission agent hors limites [0, 100]
  SELECT count(*) INTO v_badrate FROM public.agents_management
  WHERE is_active = true AND (
       COALESCE(commission_rate, 0) < 0 OR COALESCE(commission_rate, 0) > 100
    OR COALESCE(commission_agent_principal, 0) < 0 OR COALESCE(commission_agent_principal, 0) > 100
    OR COALESCE(commission_sous_agent, 0) < 0 OR COALESCE(commission_sous_agent, 0) > 100);

  -- Revenu PDG nul ou négatif
  SELECT count(*) INTO v_nonpos FROM public.revenus_pdg
  WHERE COALESCE(amount, 0) <= 0 AND created_at > now() - interval '7 days';

  RETURN jsonb_build_object('generated_at', now(), 'checks', jsonb_build_array(
    jsonb_build_object('key','commission_revenue_gap','label','Commission acheteur prélevée mais non enregistrée (revenus PDG)','severity','high','count',v_gap,'observed',v_gap),
    jsonb_build_object('key','agent_bad_rate','label','Taux de commission agent hors limites (0–100%)','severity','medium','count',v_badrate,'observed',v_badrate),
    jsonb_build_object('key','revenue_nonpositive','label','Revenu PDG nul ou négatif','severity','medium','count',v_nonpos,'observed',v_nonpos)
  ));
END;
$$;

REVOKE ALL ON FUNCTION public.commission_monitor_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.commission_monitor_report() TO service_role;

SELECT 'transfer_monitor_report() + commission_monitor_report() créées.' AS status;
