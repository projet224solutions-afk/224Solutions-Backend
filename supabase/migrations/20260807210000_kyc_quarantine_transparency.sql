-- ═══════════════════════════════════════════════════════════════════════════
-- QUARANTAINE KYC TRANSPARENTE — l'argent ne se bloque plus en silence.
-- Bug d'expérience (test terrain PDG) : vente sans KYC → crédit partiellement mis en
-- quarantaine ; la notification existante ne donne NI les 3 montants (reçu/disponible/retenu),
-- NI d'anti-spam ; la libération auto au KYC ignorait le plafond ET auto-libérait aussi les
-- quarantaines manuelles PDG ; l'approbation du dossier (vendor_kyc) ne relevait JAMAIS
-- profiles.kyc_level → la libération ne se déclenchait jamais par le parcours réel.
-- La logique de plafond/quarantaine AML est INCHANGÉE — on ajoute transparence + déblocage.
-- Blindage : notifications JAMAIS bloquantes (sous-bloc EXCEPTION), libération atomique
-- (rollback complet du bloc en cas d'erreur, la vérif KYC n'est jamais bloquée), idempotence
-- (statuts + montants décroissants), aucun GRANT nouveau au-delà de service_role.
-- Migration NOUVELLE — ne réécrit aucune migration existante.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

-- ── 0) Helper de formatage devise-aware (décimales canoniques _ccy_decimals) ─
CREATE OR REPLACE FUNCTION public._q_fmt_amount(p_amount numeric, p_ccy text)
RETURNS text LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT trim(to_char(
           round(COALESCE(p_amount, 0), public._ccy_decimals(COALESCE(p_ccy, 'GNF'))),
           'FM999G999G999G999G990' ||
           CASE WHEN public._ccy_decimals(COALESCE(p_ccy, 'GNF')) > 0
                THEN 'D' || repeat('0', public._ccy_decimals(COALESCE(p_ccy, 'GNF')))
                ELSE '' END
         )) || ' ' || COALESCE(p_ccy, 'GNF');
$$;
REVOKE ALL ON FUNCTION public._q_fmt_amount(numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._q_fmt_amount(numeric, text) TO authenticated, service_role;

-- ── 1) NOTIFIER À LA SOURCE : apply_wallet_cap_split (LE primitif du plafond) ─
-- Tout crédit plafonné passe ici (credit_user_wallet_safe, transferts same-ccy et FX).
-- On y ajoute LA notification aux 3 montants : reçu / disponible / retenu (cumul),
-- avec anti-spam 24 h (1 notification par utilisateur et par devise ; les ventes suivantes
-- METTENT À JOUR le total retenu au lieu d'empiler). Jamais bloquant (sous-bloc EXCEPTION).
-- Signature et calcul du split STRICTEMENT inchangés.
CREATE OR REPLACE FUNCTION public.apply_wallet_cap_split(
  p_user_id         uuid,
  p_wallet_id       bigint,
  p_current_balance numeric,
  p_credit          numeric,
  p_currency        text,
  p_source_type     text DEFAULT NULL,
  p_source_txn_id   text DEFAULT NULL
)
RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_cap_gnf numeric; v_bal_gnf numeric; v_credit_gnf numeric;
  v_over_gnf numeric; v_q_frac numeric; v_q_amt numeric;
  v_pending_total numeric; v_notif_id uuid; v_msg text;
BEGIN
  IF p_credit IS NULL OR p_credit <= 0 THEN RETURN COALESCE(p_credit, 0); END IF;
  v_cap_gnf := public.wallet_effective_cap(p_user_id);     -- NULL = illimité
  IF v_cap_gnf IS NULL THEN RETURN p_credit; END IF;
  v_bal_gnf    := public.convert_to_gnf(COALESCE(p_current_balance, 0), p_currency);
  v_credit_gnf := public.convert_to_gnf(p_credit, p_currency);
  v_over_gnf   := (v_bal_gnf + v_credit_gnf) - v_cap_gnf;
  IF v_over_gnf <= 0 OR v_credit_gnf <= 0 THEN RETURN p_credit; END IF;
  v_q_frac := LEAST(v_over_gnf / v_credit_gnf, 1.0);
  v_q_amt  := ROUND(p_credit * v_q_frac, 2);
  INSERT INTO public.wallet_quarantined_funds (
    user_id, wallet_id, amount, currency, source_transaction_id, source_type, reason, status)
  VALUES (
    p_user_id, p_wallet_id, v_q_amt, p_currency, p_source_txn_id, p_source_type, 'cap_exceeded', 'pending');

  -- Notification transparence (3 montants) — best-effort, ne bloque JAMAIS le crédit.
  BEGIN
    SELECT COALESCE(sum(amount), 0) INTO v_pending_total
    FROM public.wallet_quarantined_funds
    WHERE user_id = p_user_id AND status = 'pending'
      AND reason = 'cap_exceeded' AND currency = p_currency;

    v_msg := '💰 Vous avez reçu ' || public._q_fmt_amount(p_credit, p_currency) || '. '
          || public._q_fmt_amount(p_credit - v_q_amt, p_currency) || ' est disponible ; '
          || public._q_fmt_amount(v_pending_total, p_currency)
          || ' est temporairement retenu : vérifiez votre identité (KYC) pour le débloquer.';

    -- Anti-spam : 1 notification / utilisateur / devise / 24 h — on met à jour le cumul.
    SELECT id INTO v_notif_id FROM public.notifications
    WHERE user_id = p_user_id
      AND metadata->>'kind' = 'quarantine_held_cap'
      AND metadata->>'currency' = p_currency
      AND created_at > now() - interval '24 hours'
    ORDER BY created_at DESC LIMIT 1;

    IF v_notif_id IS NULL THEN
      INSERT INTO public.notifications (user_id, title, message, type, metadata)
      VALUES (p_user_id, 'Une partie de vos fonds est retenue', v_msg, 'warning',
        jsonb_build_object('kind', 'quarantine_held_cap', 'link', '/kyc',
          'currency', p_currency, 'last_received', p_credit,
          'last_available', p_credit - v_q_amt, 'pending_total', v_pending_total,
          'source_type', p_source_type, 'cap_reason', 'kyc_level'));
    ELSE
      UPDATE public.notifications
      SET message = v_msg, read = false, updated_at = now(),
          metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
            'last_received', p_credit, 'last_available', p_credit - v_q_amt,
            'pending_total', v_pending_total)
      WHERE id = v_notif_id;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '[cap split notify] % (user %)', SQLERRM, p_user_id;
  END;

  RETURN p_credit - v_q_amt;
END;
$$;
REVOKE ALL ON FUNCTION public.apply_wallet_cap_split(uuid, bigint, numeric, numeric, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_wallet_cap_split(uuid, bigint, numeric, numeric, text, text, text) TO service_role;

-- ── 2) TRIGGER DE NOTIFICATION : origines complètes + plus de doublon cap ────
-- Le bénéficiaire d'une quarantaine 'cap_exceeded' est DÉSORMAIS notifié par le primitif
-- ci-dessus (3 montants + anti-spam) → le trigger ne notifie le bénéficiaire QUE pour les
-- autres raisons (quarantaine manuelle PDG…). La notification PDG reste sur TOUTES les
-- mises en quarantaine. Les libérations AUTOMATIQUES (KYC) sont notifiées en agrégé par la
-- fonction de libération → le trigger saute leur notification unitaire (anti-spam).
CREATE OR REPLACE FUNCTION public.trg_quarantine_notify()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_pdg uuid; v_amt text; v_origin text; v_role text; v_name text; v_kyc int;
BEGIN
  v_amt := public._q_fmt_amount(NEW.amount, NEW.currency);
  v_origin := CASE
    WHEN NEW.source_type IN ('transfer_in')                        THEN 'votre paiement reçu'
    WHEN NEW.source_type IN ('agent_cash_deposit')                 THEN 'votre dépôt'
    WHEN NEW.source_type IN ('refund', 'deposit_refund')           THEN 'votre remboursement'
    WHEN NEW.source_type IN ('qr_card')                            THEN 'votre paiement par carte'
    WHEN NEW.source_type IN ('escrow_release')                     THEN 'votre vente'
    WHEN NEW.source_type IN ('quote_release')                      THEN 'votre prestation'
    WHEN NEW.source_type LIKE '%commission%'                       THEN 'votre commission'
    WHEN NEW.source_type LIKE '%payout%' OR NEW.source_type LIKE '%payment%' THEN 'votre paiement de prestation'
    ELSE 'un crédit sur votre compte'
  END;

  IF TG_OP = 'INSERT' AND NEW.status = 'pending' THEN
    -- Bénéficiaire : uniquement les quarantaines HORS plafond (le primitif couvre 'cap_exceeded').
    IF COALESCE(NEW.reason, '') <> 'cap_exceeded' THEN
      INSERT INTO public.notifications (user_id, title, message, type, metadata)
      VALUES (NEW.user_id, 'Fonds en attente de vérification',
        v_amt || ' de ' || v_origin || ' sont en attente (plafond de compte atteint). Faites vérifier votre compte pour augmenter votre plafond.',
        'warning', jsonb_build_object('kind', 'quarantine_held', 'quarantine_id', NEW.id,
          'amount', NEW.amount, 'currency', NEW.currency, 'source_type', NEW.source_type, 'link', '/kyc'));
    END IF;

    v_pdg := public.get_pdg_user_id();
    IF v_pdg IS NOT NULL AND v_pdg <> NEW.user_id THEN
      SELECT role::text, COALESCE(NULLIF(TRIM(first_name||' '||last_name),''), public_id, left(NEW.user_id::text,8)), COALESCE(kyc_level,0)
        INTO v_role, v_name, v_kyc FROM public.profiles WHERE id = NEW.user_id;
      INSERT INTO public.notifications (user_id, title, message, type, metadata)
      VALUES (v_pdg, 'Fonds en quarantaine',
        v_amt || ' en attente de votre décision — ' || COALESCE(v_role,'utilisateur') || ' ' || COALESCE(v_name,'') || ' (KYC ' || COALESCE(v_kyc,0) || ').',
        'warning', jsonb_build_object('kind', 'quarantine_pending_pdg', 'quarantine_id', NEW.id,
          'beneficiary', NEW.user_id, 'role', v_role, 'kyc_level', v_kyc, 'amount', NEW.amount, 'currency', NEW.currency, 'link', '/pdg/quarantine'));
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' AND OLD.status = 'pending' AND NEW.status <> OLD.status THEN
    IF NEW.status = 'released' THEN
      -- Libération AUTOMATIQUE (KYC) → notification agrégée posée par la fonction de
      -- libération ; on évite le doublon unitaire. Les libérations PDG restent notifiées.
      IF NOT (NEW.reviewed_by IS NULL AND COALESCE(NEW.notes, '') ILIKE '%libération automatique%') THEN
        INSERT INTO public.notifications (user_id, title, message, type, metadata)
        VALUES (NEW.user_id, 'Fonds ajoutés à votre solde',
          v_amt || ' ont été ajoutés à votre solde après vérification.',
          'success', jsonb_build_object('kind', 'quarantine_released', 'quarantine_id', NEW.id, 'amount', NEW.amount));
      END IF;
    ELSIF NEW.status = 'rejected' THEN
      INSERT INTO public.notifications (user_id, title, message, type, metadata)
      VALUES (NEW.user_id, 'Fonds non validés',
        'Votre demande de ' || v_amt || ' n''a pas été validée. Contactez le support pour en savoir plus.',
        'warning', jsonb_build_object('kind', 'quarantine_rejected', 'quarantine_id', NEW.id, 'amount', NEW.amount));
    END IF;
    RETURN NEW;
  END IF;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '[quarantine notify] % (id %)', SQLERRM, NEW.id;
  RETURN NEW;
END; $$;
REVOKE ALL ON FUNCTION public.trg_quarantine_notify() FROM PUBLIC;

-- ── 3) LIBÉRATION AUTO AU KYC : cap-aware, cap_exceeded UNIQUEMENT, agrégée ──
-- Remplace la version 20260731100000 qui (a) libérait TOUTES les quarantaines pending
-- (y compris manuelles/PDG — interdit) et (b) ignorait le nouveau plafond.
-- Désormais : seules les quarantaines 'cap_exceeded' sont libérées, DANS LA LIMITE du
-- nouveau plafond (libération partielle possible, le reliquat reste pending), avec UNE
-- notification agrégée « ✅ Identité vérifiée ». Atomique (le bloc entier réussit ou est
-- annulé) et jamais bloquant pour la mise à jour KYC (EXCEPTION → WARNING).
CREATE OR REPLACE FUNCTION public.release_quarantine_on_kyc_verified()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_cap_gnf numeric; v_bal_gnf numeric; v_headroom_gnf numeric; v_amt_gnf numeric;
  v_row RECORD; v_wallet RECORD; v_rel numeric; v_txn text; v_res jsonb;
  v_totals jsonb := '{}'::jsonb; v_ccy text; v_parts text := ''; v_dec int;
BEGIN
  IF COALESCE(NEW.kyc_level,0) <= COALESCE(OLD.kyc_level,0) THEN RETURN NEW; END IF;
  IF COALESCE(NEW.kyc_level,0) < 1 THEN RETURN NEW; END IF;

  v_cap_gnf := public.wallet_effective_cap(NEW.id);   -- NULL = illimité au nouveau palier

  FOR v_row IN
    SELECT * FROM public.wallet_quarantined_funds
    WHERE user_id = NEW.id AND status = 'pending' AND reason = 'cap_exceeded'
    ORDER BY created_at, id
    FOR UPDATE
  LOOP
    SELECT id, balance, currency INTO v_wallet
    FROM public.wallets WHERE id = v_row.wallet_id FOR UPDATE;
    IF NOT FOUND THEN CONTINUE; END IF;

    IF v_cap_gnf IS NULL THEN
      v_rel := v_row.amount;
    ELSE
      v_bal_gnf := public.convert_to_gnf(COALESCE(v_wallet.balance, 0), v_wallet.currency);
      v_headroom_gnf := v_cap_gnf - v_bal_gnf;
      IF v_headroom_gnf <= 0 THEN EXIT; END IF;
      v_amt_gnf := public.convert_to_gnf(v_row.amount, v_row.currency);
      IF v_amt_gnf <= v_headroom_gnf THEN
        v_rel := v_row.amount;
      ELSE
        v_dec := public._ccy_decimals(v_row.currency);
        v_rel := ROUND(v_row.amount * (v_headroom_gnf / v_amt_gnf), v_dec);
        IF v_rel <= 0 THEN EXIT; END IF;
      END IF;
    END IF;

    IF v_rel >= v_row.amount THEN
      -- Libération COMPLÈTE via le primitif existant (idempotent, tracé, notifie via trigger — saut auto).
      v_res := public.release_quarantined_funds(
        v_row.id, NULL,
        'Libération automatique : identité vérifiée (KYC palier ' || NEW.kyc_level::text || ')');
      IF NOT COALESCE((v_res->>'success')::boolean, false) THEN CONTINUE; END IF;
      v_rel := v_row.amount;
    ELSE
      -- Libération PARTIELLE : crédit de la part libérable, le reliquat reste en quarantaine.
      v_txn := 'qrel-' || left(replace(gen_random_uuid()::text, '-', ''), 44);
      UPDATE public.wallets SET balance = COALESCE(balance,0) + v_rel, updated_at = now()
      WHERE id = v_row.wallet_id;
      INSERT INTO public.wallet_transactions (
        transaction_id, receiver_wallet_id, receiver_user_id, amount, net_amount, currency,
        transaction_type, status, description, metadata)
      VALUES (
        v_txn, v_row.wallet_id, v_row.user_id, v_rel, v_rel, v_row.currency,
        'deposit', 'completed', 'Libération automatique partielle (identité vérifiée)',
        jsonb_build_object('source', 'quarantine_release', 'quarantine_id', v_row.id,
          'partial', true, 'auto', true, 'kyc_level', NEW.kyc_level));
      UPDATE public.wallet_quarantined_funds
      SET amount = amount - v_rel,
          notes = COALESCE(notes || ' | ', '') || 'Libération automatique partielle de '
               || public._q_fmt_amount(v_rel, currency) || ' (KYC palier ' || NEW.kyc_level::text || ')'
      WHERE id = v_row.id;
    END IF;

    v_ccy := COALESCE(v_row.currency, 'GNF');
    v_totals := jsonb_set(v_totals, ARRAY[v_ccy],
      to_jsonb(COALESCE((v_totals->>v_ccy)::numeric, 0) + v_rel));
  END LOOP;

  -- Notification agrégée (jamais bloquante).
  IF v_totals <> '{}'::jsonb THEN
    BEGIN
      SELECT string_agg(public._q_fmt_amount(value::numeric, key), ' + ')
        INTO v_parts FROM jsonb_each_text(v_totals);
      INSERT INTO public.notifications (user_id, title, message, type, metadata)
      VALUES (NEW.id, '✅ Identité vérifiée : fonds libérés',
        v_parts || ' ont été libérés sur votre solde après vérification de votre identité.',
        'success', jsonb_build_object('kind', 'quarantine_kyc_released',
          'totals', v_totals, 'kyc_level', NEW.kyc_level, 'link', '/wallet'));
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING '[kyc release notify] % (user %)', SQLERRM, NEW.id;
    END;
  END IF;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- Tout le bloc est annulé (atomique) mais la vérification KYC n'est JAMAIS bloquée.
  RAISE WARNING '[kyc auto release] % (user %)', SQLERRM, NEW.id;
  RETURN NEW;
END; $$;
REVOKE ALL ON FUNCTION public.release_quarantine_on_kyc_verified() FROM PUBLIC, anon, authenticated;
-- Le trigger trg_release_quarantine_on_kyc (AFTER UPDATE OF kyc_level ON profiles) existe déjà
-- (20260731100000) et pointe sur cette fonction — pas besoin de le recréer.

-- ── 4) PONT PARCOURS RÉEL : vendor_kyc vérifié ⇒ kyc_level ≥ 1 ───────────────
-- Trou prouvé : l'approbation du dossier (VendorKYCReview → vendor_kyc.status='verified')
-- ne touchait JAMAIS profiles.kyc_level → plafond bloqué à t0 et libération jamais déclenchée
-- par le parcours réel. Ce pont relève kyc_level à 1 (jamais de rétrogradation d'un niveau
-- supérieur), ce qui déclenche trg_release_quarantine_on_kyc ci-dessus.
CREATE OR REPLACE FUNCTION public.sync_kyc_level_on_vendor_kyc_verified()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NEW.status = 'verified'
     AND (TG_OP = 'INSERT' OR NEW.status IS DISTINCT FROM OLD.status) THEN
    UPDATE public.profiles
    SET kyc_level = 1, kyc_verified_at = COALESCE(kyc_verified_at, now())
    WHERE id = NEW.vendor_id AND COALESCE(kyc_level, 0) < 1;
  END IF;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '[vendor_kyc sync level] % (vendor %)', SQLERRM, NEW.vendor_id;
  RETURN NEW;
END; $$;
REVOKE ALL ON FUNCTION public.sync_kyc_level_on_vendor_kyc_verified() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_vendor_kyc_sync_level ON public.vendor_kyc;
CREATE TRIGGER trg_vendor_kyc_sync_level
  AFTER INSERT OR UPDATE OF status ON public.vendor_kyc
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_kyc_level_on_vendor_kyc_verified();

-- ── 5) SENTINELLE quarantine_stuck : rappel hebdo aux oubliés ────────────────
-- Fonds 'cap_exceeded' pending > 7 j sans progression KYC (kyc_level=0) → rappel à
-- l'utilisateur, dédupliqué PAR SEMAINE ISO. La visibilité PDG > 30 j existe déjà :
-- check quarantine_stale du gardien AML (wallet_provenance_report) + panneau
-- « Provenance & Plafonds » qui liste toutes les quarantaines pending avec leur âge.
CREATE OR REPLACE FUNCTION public.quarantine_stuck_sweep()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_week text := to_char(now() AT TIME ZONE 'UTC', 'IYYY-IW');
  v_user RECORD; v_sent int := 0; v_candidates int := 0;
BEGIN
  FOR v_user IN
    SELECT q.user_id, q.currency, sum(q.amount) AS total, min(q.created_at) AS oldest
    FROM public.wallet_quarantined_funds q
    JOIN public.profiles p ON p.id = q.user_id
    WHERE q.status = 'pending' AND q.reason = 'cap_exceeded'
      AND q.created_at < now() - interval '7 days'
      AND COALESCE(p.kyc_level, 0) = 0
    GROUP BY q.user_id, q.currency
  LOOP
    v_candidates := v_candidates + 1;
    IF NOT EXISTS (
      SELECT 1 FROM public.notifications
      WHERE user_id = v_user.user_id
        AND metadata->>'kind' = 'quarantine_stuck_reminder'
        AND metadata->>'week' = v_week
        AND metadata->>'currency' = v_user.currency
    ) THEN
      INSERT INTO public.notifications (user_id, title, message, type, metadata)
      VALUES (v_user.user_id, 'Des fonds vous attendent',
        public._q_fmt_amount(v_user.total, v_user.currency)
        || ' sont retenus depuis le ' || to_char(v_user.oldest, 'DD/MM/YYYY')
        || '. Vérifiez votre identité (KYC) pour les débloquer.',
        'warning', jsonb_build_object('kind', 'quarantine_stuck_reminder',
          'week', v_week, 'currency', v_user.currency, 'total', v_user.total, 'link', '/kyc'));
      v_sent := v_sent + 1;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('week', v_week, 'candidates', v_candidates, 'reminders_sent', v_sent);
END; $$;
REVOKE ALL ON FUNCTION public.quarantine_stuck_sweep() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.quarantine_stuck_sweep() TO service_role;

-- ── 6) L'HISTORIQUE DIT LA VÉRITÉ : le wrapper de confirmation remonte le split ─
-- release_escrow_to_seller (20260705170004) renvoie déjà credited/quarantined et écrit
-- metadata.quarantined sur la ligne wallet_transactions. Le wrapper appelé par le backend
-- ne remontait PAS 'quarantined' → la notification vendeur disait « fonds libérés » même
-- quand une partie était retenue. On ajoute le passthrough (aucun autre changement).
CREATE OR REPLACE FUNCTION public.confirm_delivery_and_release_escrow(
  p_escrow_id   uuid,
  p_customer_id uuid,
  p_notes       text DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_payer  uuid;
  v_buyer  uuid;
  v_status text;
  v_res    jsonb;
BEGIN
  SELECT payer_id, buyer_id, status INTO v_payer, v_buyer, v_status
  FROM public.escrow_transactions WHERE id = p_escrow_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Transaction escrow introuvable';
  END IF;
  IF COALESCE(v_payer, v_buyer) <> p_customer_id THEN
    RAISE EXCEPTION 'Non autorisé: vous n''êtes pas le client de cette transaction';
  END IF;

  v_res := public.release_escrow_to_seller(p_escrow_id, 'customer_confirmation');

  -- Déjà libéré (idempotent) → succès
  IF COALESCE((v_res->>'skipped')::boolean, false) THEN
    RETURN json_build_object('success', true, 'already_released', true, 'escrow_id', p_escrow_id);
  END IF;
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION '%', COALESCE(v_res->>'error', 'Échec de la libération');
  END IF;

  -- Notes + journal (best-effort)
  UPDATE public.escrow_transactions SET notes = COALESCE(p_notes, notes) WHERE id = p_escrow_id;
  BEGIN
    INSERT INTO public.escrow_logs (escrow_id, action, performed_by, note)
    VALUES (p_escrow_id, 'customer_release', p_customer_id, p_notes);
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  RETURN json_build_object('success', true, 'escrow_id', p_escrow_id,
    'vendor_amount', (v_res->>'vendor_amount')::numeric,
    'credited', (v_res->>'credited')::numeric, 'credited_currency', v_res->>'credited_currency',
    'quarantined', (v_res->>'quarantined')::numeric,
    'commission_amount', (v_res->>'commission_amount')::numeric, 'released_at', now());
END;
$$;

COMMIT;

-- ── 7) PLANIFICATION (hors transaction, défensive) — 1×/jour 08:10 UTC ───────
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('quarantine-stuck-sweep')
      WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'quarantine-stuck-sweep');
    PERFORM cron.schedule('quarantine-stuck-sweep', '10 8 * * *', 'SELECT public.quarantine_stuck_sweep();');
  ELSE
    RAISE NOTICE 'pg_cron absent : planifier quarantine_stuck_sweep autrement (étage B).';
  END IF;
END $$;
