-- ═══════════════════════════════════════════════════════════════════════════
-- ESCROW LIBÉRÉ SANS TRACE — enquête permanente + réparation VALIDÉE PAR LE PDG.
--
-- ENQUÊTE DU CAS 083ace93 (150 000 GNF, commande 60067b50) — preuves :
--   • 21/07 01:52:53 : l'acheteur EST débité de 157 500 (150 000 + 7 500 de commission)
--     — prouvé par wallet_balance_audit (delta −157 500) ET wallet_transactions ;
--   • le vendeur (dad61558) a un wallet à **0 GNF** et **AUCUNE ligne wallet_balance_audit**
--     depuis la création de l'audit (08/06) : son solde n'a JAMAIS bougé ;
--   • 04/08 02:00:05 : l'escrow passe à `released`, `released_by` = NULL, `transaction_id`
--     = NULL, aucun escrow_log, aucune ligne de libération.
--   → VERDICT : **JAMAIS CRÉDITÉ**. Le vendeur est CRÉANCIER de 150 000 GNF.
--
-- CHEMIN IDENTIFIÉ : les 5 cas connus sont tous à des heures de cron (02:00:05, 01:30:03,
-- 01:00:01, 03:15:02, 21:00:02) avec released_by NULL → l'Edge Function
-- `production-cron-jobs` (pg_cron toutes les 15 min). Son code SOURCE est déjà corrigé
-- (il délègue à release_escrow_to_seller) mais la version DÉPLOYÉE est l'ancienne, qui
-- faisait un simple `UPDATE status='released'` sans créditer — d'où ces cas.
-- ⚠️ ACTION HORS SQL REQUISE : redéployer (ou retirer) cette Edge Function. Dit au rapport.
--
-- CE QUE FAIT CETTE MIGRATION :
--   1. `escrow_no_ledger_investigate(id)` — le dossier de preuves (a/b/c) automatique :
--      l'enquête d'aujourd'hui devient un outil permanent de l'onglet Escrow ;
--   2. `escrow_no_ledger_repair(id)` — la réparation par le flux NORMAL
--      (credit_user_wallet_safe : le KYC 0 enverra l'excédent en quarantaine, ce qui est
--      CORRECT et désormais notifié), idempotente (`escrow-repair:<id>`), tracée created_by.
--      ⚠️ Elle n'est JAMAIS appelée automatiquement : le PDG clique.
--   3. `release_escrow_funds` — chemin qui crédite par UPDATE direct SANS ligne d'historique :
--      REVOKE de son exécution (plus personne ne peut poser `released` hors du primitif).
-- Migration NOUVELLE. Aucune sortie d'argent sans clic PDG.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

-- ── 1) LE DOSSIER DE PREUVES (lecture seule, PDG) ──────────────────────────
CREATE OR REPLACE FUNCTION public.escrow_no_ledger_investigate(p_escrow_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_e record; v_seller uuid; v_wallet record; v_credit_found jsonb; v_debit jsonb;
  v_audit jsonb; v_verdict text; v_repaired boolean;
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT * INTO v_e FROM public.escrow_transactions WHERE id = p_escrow_id;
  IF v_e.id IS NULL THEN RETURN jsonb_build_object('found', false); END IF;
  v_seller := COALESCE(v_e.receiver_id, v_e.seller_id);

  SELECT id, balance, currency INTO v_wallet FROM public.wallets
  WHERE user_id = v_seller AND currency = COALESCE(v_e.currency, 'GNF') ORDER BY id LIMIT 1;

  -- (a) Le solde du vendeur a-t-il bougé autour de la libération ? (±1 h)
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'at', a.changed_at, 'delta', a.new_balance - a.old_balance)), '[]'::jsonb)
    INTO v_audit
  FROM public.wallet_balance_audit a
  WHERE a.user_id = v_seller
    AND a.changed_at BETWEEN v_e.released_at - interval '1 hour'
                         AND v_e.released_at + interval '1 hour';

  -- (b) Une ligne de LIBÉRATION existe-t-elle ?
  SELECT COALESCE(jsonb_agg(jsonb_build_object('tx', wt.transaction_id, 'type', wt.transaction_type,
      'net', wt.net_amount, 'at', wt.created_at)), '[]'::jsonb)
    INTO v_credit_found
  FROM public.wallet_transactions wt
  WHERE wt.metadata->>'escrow_id' = p_escrow_id::text
     OR wt.transaction_id = 'escrow-repair:' || p_escrow_id::text;

  -- (c) L'acheteur a-t-il bien été débité ? (les fonds ont-ils existé ?)
  SELECT COALESCE(jsonb_agg(jsonb_build_object('type', wt.transaction_type, 'amt', wt.amount,
      'at', wt.created_at)), '[]'::jsonb)
    INTO v_debit
  FROM public.wallet_transactions wt
  WHERE wt.sender_user_id = COALESCE(v_e.payer_id, v_e.buyer_id)
    AND wt.created_at BETWEEN v_e.created_at - interval '5 minutes'
                          AND v_e.created_at + interval '5 minutes';

  v_repaired := EXISTS (SELECT 1 FROM public.wallet_transactions
                        WHERE transaction_id = 'escrow-repair:' || p_escrow_id::text);

  v_verdict := CASE
    WHEN v_repaired THEN 'REPARE (crédit déjà passé par la réparation validée)'
    WHEN jsonb_array_length(v_credit_found) > 0 THEN 'TRACE PRESENTE (le gardien devrait être vert)'
    WHEN jsonb_array_length(v_audit) > 0 THEN 'CREDITE NON TRACE (solde bougé, ligne manquante) — backfill de la ligne'
    ELSE 'JAMAIS CREDITE — le vendeur est CREANCIER de ' || v_e.amount || ' ' || COALESCE(v_e.currency,'GNF')
  END;

  RETURN jsonb_build_object(
    'found', true, 'escrow_id', p_escrow_id, 'montant', v_e.amount, 'devise', COALESCE(v_e.currency,'GNF'),
    'statut', v_e.status, 'libere_le', v_e.released_at, 'libere_par', v_e.released_by,
    'vendeur', v_seller, 'wallet_vendeur', to_jsonb(v_wallet),
    'a_mouvements_solde_autour', v_audit,
    'b_ligne_liberation', v_credit_found,
    'c_debit_acheteur', v_debit,
    'deja_repare', v_repaired,
    'verdict', v_verdict,
    'action', CASE WHEN v_repaired OR jsonb_array_length(v_credit_found) > 0 THEN 'aucune'
                   ELSE 'escrow_no_ledger_repair(' || p_escrow_id || ') — VALIDATION PDG REQUISE' END);
END $$;
REVOKE ALL ON FUNCTION public.escrow_no_ledger_investigate(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.escrow_no_ledger_investigate(uuid) TO authenticated, service_role;

-- ── 2) LA RÉPARATION — clic PDG obligatoire, idempotente, flux normal ──────
CREATE OR REPLACE FUNCTION public.escrow_no_ledger_repair(p_escrow_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_e record; v_seller uuid; v_actor uuid := auth.uid(); v_key text;
  v_res jsonb; v_wallet bigint; v_moved boolean;
BEGIN
  -- Sortie d'argent : JAMAIS automatique. Le PDG doit être l'appelant.
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF v_actor IS NULL THEN RAISE EXCEPTION 'ACTEUR_REQUIS : réparation manuelle uniquement (aucun appel automatique)'; END IF;

  SELECT * INTO v_e FROM public.escrow_transactions WHERE id = p_escrow_id FOR UPDATE;
  IF v_e.id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'ESCROW_INTROUVABLE'); END IF;
  IF v_e.status <> 'released' THEN
    RETURN jsonb_build_object('success', false, 'error', 'STATUT_INATTENDU : ' || v_e.status);
  END IF;

  v_key := 'escrow-repair:' || p_escrow_id::text;
  -- IDEMPOTENCE : une réparation, une seule fois, même en cas de double clic.
  IF EXISTS (SELECT 1 FROM public.wallet_transactions WHERE transaction_id = v_key) THEN
    RETURN jsonb_build_object('success', true, 'skipped', true, 'raison', 'DEJA_REPARE');
  END IF;

  v_seller := COALESCE(v_e.receiver_id, v_e.seller_id);

  -- Le solde a-t-il bougé au moment de la libération ? (distingue les deux réparations)
  SELECT EXISTS (SELECT 1 FROM public.wallet_balance_audit a
                 WHERE a.user_id = v_seller AND a.new_balance > a.old_balance
                   AND a.changed_at BETWEEN v_e.released_at - interval '1 hour'
                                        AND v_e.released_at + interval '1 hour')
    INTO v_moved;

  IF v_moved THEN
    -- CRÉDITÉ NON TRACÉ : on n'ajoute QUE la ligne d'historique manquante (aucun mouvement).
    SELECT id INTO v_wallet FROM public.wallets
      WHERE user_id = v_seller AND currency = COALESCE(v_e.currency,'GNF') ORDER BY id LIMIT 1;
    INSERT INTO public.wallet_transactions (
      transaction_id, receiver_wallet_id, receiver_user_id, amount, net_amount, currency,
      transaction_type, status, description, metadata, created_at)
    VALUES (v_key, v_wallet, v_seller, v_e.amount, v_e.amount, COALESCE(v_e.currency,'GNF'),
      'escrow_release', 'completed',
      'Libération d''escrow journalisée a posteriori (réparation validée PDG)',
      jsonb_build_object('escrow_id', p_escrow_id, 'repair', 'ledger_only',
        'note', 'Le solde avait déjà bougé : AUCUN mouvement d''argent, seule la trace manquait.',
        'validated_by', v_actor),
      v_e.released_at);
    RETURN jsonb_build_object('success', true, 'mode', 'ligne_seule', 'montant', v_e.amount);
  END IF;

  -- JAMAIS CRÉDITÉ : on paie le vendeur par le FLUX NORMAL (plafond KYC → quarantaine
  -- transparente et notifiée si dépassement — comportement voulu, pas contourné).
  v_res := public.credit_user_wallet_safe(v_seller, v_e.amount, COALESCE(v_e.currency,'GNF'),
             'escrow_release_repair', p_escrow_id::text);

  SELECT id INTO v_wallet FROM public.wallets
    WHERE user_id = v_seller AND currency = COALESCE(v_e.currency,'GNF') ORDER BY id LIMIT 1;

  INSERT INTO public.wallet_transactions (
    transaction_id, receiver_wallet_id, receiver_user_id, amount, net_amount, currency,
    transaction_type, status, description, metadata)
  VALUES (v_key, v_wallet, v_seller, v_e.amount, v_e.amount, COALESCE(v_e.currency,'GNF'),
    'escrow_release', 'completed',
    'Libération d''escrow due au vendeur (réparation validée PDG)',
    jsonb_build_object('escrow_id', p_escrow_id, 'repair', 'credit_and_ledger',
      'credited', v_res->'credited', 'quarantined', v_res->'quarantined',
      'validated_by', v_actor));

  UPDATE public.escrow_transactions
  SET transaction_id = v_key, notes = COALESCE(notes || ' | ', '') || 'Réparé (validation PDG)'
  WHERE id = p_escrow_id;

  RETURN jsonb_build_object('success', true, 'mode', 'credit_et_ligne',
    'montant', v_e.amount, 'credite', v_res->'credited', 'en_quarantaine', v_res->'quarantined');
END $$;
-- Triple garde : (1) aucun grant service_role → aucun job ne peut l'appeler ; (2) rôle PDG
-- vérifié dans le corps ; (3) auth.uid() obligatoire → il FAUT un humain connecté.
REVOKE ALL ON FUNCTION public.escrow_no_ledger_repair(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.escrow_no_ledger_repair(uuid) TO authenticated;

-- ── 3) FERMER LE CHEMIN FAUTIF ────────────────────────────────────────────
-- `release_escrow_funds` crédite par UPDATE direct du solde, SANS ligne d'historique :
-- c'est exactement ce qui fabrique des « released sans trace ». Plus personne ne l'exécute.
REVOKE EXECUTE ON FUNCTION public.release_escrow_funds(uuid, uuid, text) FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION public.release_escrow_funds(uuid, uuid, text) IS
'DÉSACTIVÉE le 08/08/2026 : créditait le vendeur par UPDATE direct SANS écrire wallet_transactions
→ statut released sans trace (famille du cas 083ace93). Utiliser release_escrow_to_seller
(atomique, fail-closed, écrit la ligne). EXECUTE révoqué à tous les rôles.';

COMMIT;
