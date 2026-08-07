-- ============================================================================
-- 💰 AUTO-LIBÉRATION ESCROW : migration Edge Function → backend Node + capteur de vie
-- ----------------------------------------------------------------------------
-- CONTEXTE (enquête escrow du 08/08/2026) : la libération automatique des escrows
-- vivait dans l'Edge Function `production-cron-jobs`, 3e lieu de déploiement, avec
-- une dérive PROUVÉE — version déployée d'avril (UPDATE brut status='released' SANS
-- créditer le vendeur) alors que le code source était corrigé depuis. Résultat :
-- 5 escrows « libérés », 401 000 GNF jamais versés à 2 vendeurs, pendant ~2 mois.
--
-- CE FICHIER FAIT DEUX CHOSES :
--   1) enregistre le job backend `escrow_auto_release` au registre Fatome (le Général
--      le supervise comme les autres : heartbeat attendu toutes les 15 min) ;
--   2) ajoute au domaine escrow un capteur qui DÉTECTE UN JOB MORT en 1 heure.
--
-- POURQUOI UN NOUVEAU CAPTEUR alors que `held_overdue` existe : `held_overdue` ne
-- se déclenche qu'à 14 JOURS et compte les escrows échus TOUS confondus (y compris
-- ceux que le vendeur n'a jamais confirmés — normal qu'ils dorment). Il n'aurait
-- JAMAIS signalé un job d'auto-libération mort : il l'a d'ailleurs laissé passer.
-- Le nouveau capteur compte STRICTEMENT les escrows ÉLIGIBLES (échus + confirmés
-- vendeur + hors litige) — exactement la file d'attente du job. Si cette file n'est
-- pas vidée en 1 h, c'est que PERSONNE ne libère : le job est mort. Aucun autre
-- capteur du domaine n'est modifié.
--
-- Aucune logique d'argent ici : ce fichier ne crédite ni ne débite rien.
-- ============================================================================

-- ── 1) Le job entre au registre Fatome (supervisé par le Général) ───────────
INSERT INTO public.fatome_registry (fatome_key, label, heartbeat_source, health_check_rpc, expected_interval_sec, criticality)
VALUES ('escrow_auto_release', 'Auto-libération escrow (backend)', NULL, 'escrow_monitor_report', 900, 'critical')
ON CONFLICT (fatome_key) DO UPDATE
  SET label = EXCLUDED.label,
      expected_interval_sec = EXCLUDED.expected_interval_sec,
      health_check_rpc = EXCLUDED.health_check_rpc,
      criticality = EXCLUDED.criticality;

-- ── 2) Capteur « auto-libération vivante » ajouté au domaine escrow ────────
-- Recréé À L'IDENTIQUE de 20260704120000 + le capteur auto_release_dead.
CREATE OR REPLACE FUNCTION public.escrow_monitor_report()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_non_converted   int;
  v_net_mismatch    int;
  v_cur_mismatch    int;
  v_no_ledger       int;
  v_held_overdue    int;
  v_stale_rates     int;
  v_rapid           int;
  v_escrow_mismatch int;
  v_autorel_dead    int;
BEGIN
  SELECT count(*) INTO v_non_converted FROM public.wallet_transactions
  WHERE transaction_type = 'payment' AND description LIKE 'Libération escrow%'
    AND COALESCE(metadata->>'reversed', '') <> 'true'
    AND created_at > now() - interval '7 days';
  SELECT count(*) INTO v_net_mismatch FROM public.wallet_transactions
  WHERE COALESCE(net_amount, 0) <> COALESCE(amount, 0) - COALESCE(fee, 0)
    AND created_at > now() - interval '7 days';
  SELECT count(*) INTO v_cur_mismatch FROM public.wallet_transactions wt
  JOIN public.escrow_transactions e ON e.id::text = wt.metadata->>'escrow_id'
  WHERE wt.transaction_type = 'escrow_release'
    AND wt.currency <> COALESCE(e.currency, 'GNF')
    AND wt.created_at > now() - interval '7 days';
  SELECT count(*) INTO v_no_ledger FROM public.escrow_transactions e
  WHERE e.status = 'released' AND e.released_at > now() - interval '7 days'
    AND NOT EXISTS (
      SELECT 1 FROM public.wallet_transactions wt
      WHERE (wt.reference_id = e.id::text OR wt.metadata->>'escrow_id' = e.id::text)
        AND (
          wt.transaction_type = 'escrow_release'
          OR (wt.transaction_type = 'payment' AND wt.description LIKE 'Libération escrow%')
        ));
  SELECT count(*) INTO v_held_overdue FROM public.escrow_transactions
  WHERE status = 'held' AND auto_release_at IS NOT NULL
    AND auto_release_at < now() - interval '14 days';

  -- ✚ NOUVEAU : la file d'attente EXACTE du job d'auto-libération. Mêmes critères que
  -- le job backend (held + échu + seller_confirmed_at NOT NULL + hors litige). Si un
  -- seul escrow y stagne plus d'1 h, le job ne tourne plus — argent dû, vendeur non payé.
  SELECT count(*) INTO v_autorel_dead FROM public.escrow_transactions
  WHERE status = 'held'
    AND auto_release_at IS NOT NULL
    AND auto_release_at < now() - interval '1 hour'
    AND seller_confirmed_at IS NOT NULL
    AND dispute_status IS NULL;

  SELECT count(*) INTO v_stale_rates FROM public.currency_exchange_rates
  WHERE is_active = true AND (from_currency = 'GNF' OR to_currency = 'GNF')
    AND source_type IN ('official_html', 'official_fixed_parity')
    AND COALESCE(retrieved_at, timestamptz '2000-01-01') < now() - interval '24 hours';
  SELECT count(*) INTO v_rapid FROM public.wallet_transactions
  WHERE transaction_type IN ('escrow_release', 'refund')
    AND created_at > now() - interval '5 minutes';
  SELECT count(*) INTO v_escrow_mismatch FROM public.escrow_transactions e
  JOIN public.orders o ON o.id = e.order_id
  WHERE o.subtotal IS NOT NULL AND e.amount > o.subtotal + 0.01
    AND e.status = 'held'
    AND e.created_at > now() - interval '30 days';

  RETURN jsonb_build_object(
    'generated_at', now(),
    'checks', jsonb_build_array(
      jsonb_build_object('key','non_converted_releases','label','Libérations non converties (Edge cassée)','severity','critical','count',v_non_converted,'observed',v_non_converted),
      jsonb_build_object('key','net_mismatch','label','Incohérence net ≠ montant − frais','severity','critical','count',v_net_mismatch,'observed',v_net_mismatch),
      jsonb_build_object('key','currency_mismatch','label','Devise de libération ≠ devise escrow','severity','high','count',v_cur_mismatch,'observed',v_cur_mismatch),
      jsonb_build_object('key','released_no_ledger','label','Escrow libéré sans trace d''historique','severity','high','count',v_no_ledger,'observed',v_no_ledger),
      jsonb_build_object('key','auto_release_dead','label','Auto-libération en panne : escrows éligibles non libérés > 1h','severity','critical','count',v_autorel_dead,'observed',v_autorel_dead),
      jsonb_build_object('key','held_overdue','label','Escrow bloqué > 14j (cron en panne ?)','severity','medium','count',v_held_overdue,'observed',v_held_overdue),
      jsonb_build_object('key','stale_rates','label','Taux BCRG officiels périmés > 24h (conversion à risque)','severity','high','count',v_stale_rates,'observed',v_stale_rates),
      jsonb_build_object('key','rapid_ops','label','Opérations escrow rapides (5 min) — possible attaque','severity',CASE WHEN v_rapid > 30 THEN 'high' ELSE 'low' END,'count',CASE WHEN v_rapid > 30 THEN v_rapid ELSE 0 END,'observed',v_rapid),
      jsonb_build_object('key','escrow_amount_mismatch','label','Escrow ACTIF > montant produit (commission incluse → fuite)','severity','critical','count',v_escrow_mismatch,'observed',v_escrow_mismatch)
    )
  );
END;
$$;

SELECT 'Job escrow_auto_release enregistré (900s) + capteur auto_release_dead (>1h) actif.' AS status;
