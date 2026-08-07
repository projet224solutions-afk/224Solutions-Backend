-- ═══════════════════════════════════════════════════════════════════════════
-- CAPTEUR AML « hausse sans trace » — RÉGLAGE FINAL (correction de 20260807310000).
-- Erreur corrigée : la borne seule élargissait la fenêtre (13 → 121 cas) car le capteur
-- d'origine travaillait sur une période RÉCENTE. Un capteur temps réel doit regarder une
-- FENÊTRE GLISSANTE (sinon il ne redescend jamais à 0, même après traitement).
-- → fenêtre = 7 jours glissants, jamais avant la borne des gardiens.
--
-- SÉVÉRITÉ ajustée à `high` avec le libellé EXACT du phénomène : le diagnostic du 07/08 a
-- établi qu'il ne s'agit PAS d'argent volé mais du même défaut que pour le coffre —
-- `credit_user_wallet_safe` crédite le solde sans écrire au grand livre, et l'appelant
-- n'écrit la ligne que pour certains bénéficiaires. Garder « critical » sur un défaut
-- structurel connu = SMS permanents = accoutumance = vraies alertes noyées.
-- Le chantier de fond (tracer le primitif) est à mener À FROID sur les flux d'argent.
-- Migration NOUVELLE.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE OR REPLACE FUNCTION public.wallet_provenance_report()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_since timestamptz := GREATEST(public.guardian_baseline_at(), now() - interval '7 days');
  v_untraced int := 0; v_untraced_amt numeric := 0;
  v_over_cap int := 0; v_q_pending int := 0; v_q_stale int := 0;
BEGIN
  SELECT count(*), COALESCE(sum(wba.new_balance - wba.old_balance), 0)
    INTO v_untraced, v_untraced_amt
  FROM public.wallet_balance_audit wba
  WHERE wba.new_balance > wba.old_balance
    AND wba.changed_at >= v_since
    AND NOT EXISTS (SELECT 1 FROM public.wallet_transactions wt
                    WHERE (wt.receiver_wallet_id = wba.wallet_id OR wt.sender_wallet_id = wba.wallet_id)
                      AND wt.created_at BETWEEN wba.changed_at - interval '10 minutes'
                                            AND wba.changed_at + interval '10 minutes')
    AND NOT EXISTS (SELECT 1 FROM public.revenus_pdg r
                    WHERE r.user_id = wba.user_id
                      AND r.created_at BETWEEN wba.changed_at - interval '10 minutes'
                                           AND wba.changed_at + interval '10 minutes')
    AND NOT EXISTS (SELECT 1 FROM public.platform_revenue pr
                    WHERE pr.created_at BETWEEN wba.changed_at - interval '10 minutes'
                                            AND wba.changed_at + interval '10 minutes')
    AND NOT EXISTS (SELECT 1 FROM public.agent_commissions_log acl
                    WHERE acl.created_at BETWEEN wba.changed_at - interval '10 minutes'
                                             AND wba.changed_at + interval '10 minutes');

  SELECT count(*) INTO v_over_cap FROM public.wallets w
  WHERE public.wallet_effective_cap(w.user_id) IS NOT NULL
    AND public.convert_to_gnf(COALESCE(w.balance,0), w.currency) > public.wallet_effective_cap(w.user_id);

  SELECT count(*) INTO v_q_pending FROM public.wallet_quarantined_funds WHERE status = 'pending';
  SELECT count(*) INTO v_q_stale FROM public.wallet_quarantined_funds
  WHERE status = 'pending' AND created_at < now() - interval '7 days';

  RETURN jsonb_build_object('generated_at', now(), 'window_since', v_since, 'checks', jsonb_build_array(
    jsonb_build_object('key','untraced_increase','label','Crédits sans ligne de grand livre (7 j) — traçabilité manquante, argent encaissé mais non journalisé','severity','high','count',v_untraced,'observed',v_untraced_amt),
    jsonb_build_object('key','wallet_over_cap','label','Wallet au-dessus de son plafond de détention (à examiner)','severity','high','count',v_over_cap,'observed',v_over_cap),
    jsonb_build_object('key','quarantine_pending','label','Fonds en quarantaine en attente de décision PDG','severity','high','count',v_q_pending,'observed',v_q_pending),
    jsonb_build_object('key','quarantine_stale','label','Quarantaine non traitée depuis > 7 jours','severity','medium','count',v_q_stale,'observed',v_q_stale)
  ));
END; $$;
REVOKE ALL ON FUNCTION public.wallet_provenance_report() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.wallet_provenance_report() TO service_role;

COMMIT;
