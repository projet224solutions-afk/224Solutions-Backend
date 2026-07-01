-- ════════════════════════════════════════════════════════════════════════════
-- ÉTAPE 11 — RÉGULARISATION de la DETTE DU MINT (unique, atomique, idempotente).
-- ════════════════════════════════════════════════════════════════════════════
-- Avant le fix 20260630_01, des commissions ont été VERSÉES aux agents SANS débit
-- du PDG (mint). La surveillance (check_commission_conservation) chiffre cet écart.
-- Ici on RÉGULARISE : le PDG « paie » rétroactivement ce qu'il aurait dû payer.
--   • Pour chaque JOUR où (crédits agents validés) > (payouts PDG déjà tracés), on
--     insère UNE ligne payout 'agent_commission_payout' du shortfall du jour (datée
--     de CE jour → la réconciliation quotidienne s'équilibre), marquée
--     metadata.kind='mint_regularization' (traçable).
--   • On DÉBITE le wallet PDG du total, UNE fois, dans la même transaction.
--   • FAIL-CLOSED : si le wallet PDG ne couvre pas le total → EXCEPTION, rien n'est
--     modifié (approvisionner puis relancer).
--   • IDEMPOTENT : le shortfall = crédits agents − payouts (incluant les
--     régularisations déjà faites). Relancer trouve un shortfall ≤ 0 → ne fait RIEN.
--   • Verrou FOR UPDATE sur le wallet PDG (atomicité vs commissions concurrentes).
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

DO $$
DECLARE
  v_pdg   uuid := public.get_pdg_user_id();
  v_bal   numeric;
  v_total numeric;
BEGIN
  IF v_pdg IS NULL THEN
    RAISE EXCEPTION 'PDG introuvable — régularisation annulée.';
  END IF;

  -- Verrou du wallet PDG (source du débit).
  SELECT balance INTO v_bal FROM public.wallets
  WHERE user_id = v_pdg AND currency = 'GNF' FOR UPDATE;
  IF v_bal IS NULL THEN
    RAISE EXCEPTION 'Wallet PDG GNF introuvable — régularisation annulée.';
  END IF;

  -- Total du shortfall = somme, par jour, de (crédits agents validés − payouts déjà tracés)
  -- pour les jours où c'est positif. Les régularisations précédentes comptent comme payouts
  -- → relancer donne 0 (idempotent).
  SELECT COALESCE(sum(sub.shortfall), 0) INTO v_total
  FROM (
    WITH a AS (
      SELECT date_trunc('day', created_at) AS j, sum(amount) AS s
      FROM public.agent_commissions_log WHERE status = 'validated' GROUP BY 1
    ),
    p AS (
      SELECT date_trunc('day', created_at) AS j, sum(-amount) AS s
      FROM public.platform_revenue WHERE revenue_type = 'agent_commission_payout' GROUP BY 1
    )
    SELECT ROUND(a.s - COALESCE(p.s, 0), 2) AS shortfall
    FROM a LEFT JOIN p ON a.j = p.j
    WHERE ROUND(a.s - COALESCE(p.s, 0), 2) > 0
  ) sub;

  IF v_total <= 0 THEN
    RAISE NOTICE 'Aucune dette de mint à régulariser (écart ≤ 0). Rien à faire.';
    RETURN;
  END IF;

  IF v_total > v_bal THEN
    RAISE EXCEPTION 'Solde PDG insuffisant pour régulariser la dette (% GNF < % GNF requis). Approvisionnez le wallet PDG puis relancez.',
      v_bal, v_total;
  END IF;

  -- Ligne payout de régularisation par jour (datée du jour des commissions).
  INSERT INTO public.platform_revenue (revenue_type, amount, source_transaction_id, metadata, created_at)
  SELECT 'agent_commission_payout', -sub.shortfall, NULL,
         jsonb_build_object(
           'kind', 'mint_regularization',
           'reason', 'Régularisation dette mint : commissions agents versées sans débit PDG avant fix 20260630_01',
           'shortfall', sub.shortfall,
           'regularized_at', now()
         ),
         sub.jour
  FROM (
    WITH a AS (
      SELECT date_trunc('day', created_at) AS j, sum(amount) AS s
      FROM public.agent_commissions_log WHERE status = 'validated' GROUP BY 1
    ),
    p AS (
      SELECT date_trunc('day', created_at) AS j, sum(-amount) AS s
      FROM public.platform_revenue WHERE revenue_type = 'agent_commission_payout' GROUP BY 1
    )
    SELECT a.j AS jour, ROUND(a.s - COALESCE(p.s, 0), 2) AS shortfall
    FROM a LEFT JOIN p ON a.j = p.j
    WHERE ROUND(a.s - COALESCE(p.s, 0), 2) > 0
  ) sub;

  -- Débit PDG du total régularisé, une seule fois.
  UPDATE public.wallets SET balance = balance - v_total, updated_at = now()
  WHERE user_id = v_pdg AND currency = 'GNF';

  RAISE NOTICE '✅ Régularisation mint : PDG débité de % GNF. Solde % → %. Conservation rétablie.',
    v_total, v_bal, v_bal - v_total;
END $$;

COMMIT;
