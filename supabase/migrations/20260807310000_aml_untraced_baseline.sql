-- ═══════════════════════════════════════════════════════════════════════════
-- CAPTEUR AML « hausse de solde sans transaction » — aligné sur le diagnostic du 07/08.
-- Il comptait TOUT l'historique et ne regardait QUE wallet_transactions : une hausse tracée
-- dans un AUTRE livre (revenus_pdg, platform_revenue, agent_commissions_log) était comptée
-- comme « argent injecté hors circuit », et les faits pré-baseline criaient éternellement.
-- Désormais : going-forward (guardian_baseline_at) + traces alternatives acceptées.
-- Le DÉTAIL reste consultable par le PDG (aml_untraced_increases). Les autres contrôles du
-- rapport (plafonds, quarantaine) sont RECOPIÉS À L'IDENTIQUE. Migration NOUVELLE.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE OR REPLACE FUNCTION public.wallet_provenance_report()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_since timestamptz := public.guardian_baseline_at();
  v_untraced int := 0; v_over_cap int := 0; v_q_pending int := 0; v_q_stale int := 0;
BEGIN
  -- 1) Hausse de solde SANS AUCUNE trace (ni ledger, ni revenu PDG, ni commission agent).
  SELECT count(*) INTO v_untraced
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

  -- 2) Wallets au-dessus de leur plafond de détention (inchangé).
  SELECT count(*) INTO v_over_cap FROM public.wallets w
  WHERE public.wallet_effective_cap(w.user_id) IS NOT NULL
    AND public.convert_to_gnf(COALESCE(w.balance,0), w.currency) > public.wallet_effective_cap(w.user_id);

  -- 3/4) Quarantaine en attente / non traitée depuis > 7 j (inchangé).
  SELECT count(*) INTO v_q_pending FROM public.wallet_quarantined_funds WHERE status = 'pending';
  SELECT count(*) INTO v_q_stale FROM public.wallet_quarantined_funds
  WHERE status = 'pending' AND created_at < now() - interval '7 days';

  RETURN jsonb_build_object('generated_at', now(), 'baseline_at', v_since, 'checks', jsonb_build_array(
    jsonb_build_object('key','untraced_increase','label','Hausse de solde sans AUCUNE trace (ledger, revenu PDG, commission) — argent hors circuit','severity','critical','count',v_untraced,'observed',v_untraced),
    jsonb_build_object('key','wallet_over_cap','label','Wallet au-dessus de son plafond de détention (à examiner)','severity','high','count',v_over_cap,'observed',v_over_cap),
    jsonb_build_object('key','quarantine_pending','label','Fonds en quarantaine en attente de décision PDG','severity','high','count',v_q_pending,'observed',v_q_pending),
    jsonb_build_object('key','quarantine_stale','label','Quarantaine non traitée depuis > 7 jours','severity','medium','count',v_q_stale,'observed',v_q_stale)
  ));
END; $$;
REVOKE ALL ON FUNCTION public.wallet_provenance_report() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.wallet_provenance_report() TO service_role;

COMMIT;
