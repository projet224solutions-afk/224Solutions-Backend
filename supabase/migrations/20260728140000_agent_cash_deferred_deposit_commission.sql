-- ============================================================================
-- ⚠️ NON APPLIQUÉE — livrée pour validation (mouvement d'argent réel).
-- Commission agent cash : part de l'agent de DÉPÔT payée EN DIFFÉRÉ, au retrait.
-- ============================================================================
-- Modèle (spéc. Thierno) : un seul frais = RETRAIT 1 % (min 1 000 GNF), payé par
-- le client. Partagé : agent RETRAIT 25 %, agent DÉPÔT 20 % (différé), plateforme 55 %.
-- Le dépôt reste GRATUIT ; l'agent de dépôt est payé quand l'argent qu'il a fait
-- entrer est retiré. Attribution FIFO par lots ; même agent aux 2 bouts = 45 % ;
-- pas d'expiration, crédit instantané au retrait ; lots historiques reconstruits
-- (sans paiement rétroactif sur les retraits passés). Points validés par Thierno.
--
-- Choix d'implémentation : la logique est ajoutée par 2 TRIGGERS atomiques (même
-- transaction que dépôt/retrait) plutôt qu'en réécrivant les 2 fonctions monétaires
-- de 100+ lignes — AUCUN doublon de fonction, atomicité identique, risque minimal
-- sur du code qui touche le coffre PDG. Réutilise la machinerie existante
-- (_acash_fx, _acash_credit/debit_wallet, _acash_currency_rules→d_share, plafond
-- journalier, bascule agent_commission_pending, devise du wallet agent).
-- ============================================================================

-- ── 1) Nouveau leg dans le CHECK du ledger ──────────────────────────────────
ALTER TABLE public.agent_cash_ledger DROP CONSTRAINT IF EXISTS agent_cash_ledger_leg_check;
ALTER TABLE public.agent_cash_ledger ADD CONSTRAINT agent_cash_ledger_leg_check
  CHECK (leg = ANY (ARRAY[
    'client_debit','client_credit','client_fee_debit',
    'agent_wallet_debit','agent_wallet_credit','agent_float_credit','agent_float_debit',
    'pdg_fee_credit','pdg_commission_debit','agent_commission_credit','agent_commission_debit',
    'agent_personal_credit','float_merge_to_wallet','commission_merge_to_wallet',
    'commission_reversal_debit','commission_reversal_credit',
    'deposit_agent_deferred_credit'   -- ⇐ part différée de l'agent de dépôt (au retrait)
  ]));

-- ── 2) Table des lots de dépôt (FIFO) ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.agent_cash_deposit_lots (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  agent_id         uuid NOT NULL REFERENCES public.agents_management(id),
  client_user_id   uuid NOT NULL,
  parent_tx_id     uuid NOT NULL,                 -- dépôt d'origine
  amount_initial   numeric NOT NULL CHECK (amount_initial > 0),
  amount_remaining numeric NOT NULL CHECK (amount_remaining >= 0),
  currency         text NOT NULL,
  created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_acdl_fifo ON public.agent_cash_deposit_lots (client_user_id, currency, created_at, id) WHERE amount_remaining > 0;
CREATE UNIQUE INDEX IF NOT EXISTS idx_acdl_parent ON public.agent_cash_deposit_lots (parent_tx_id);

ALTER TABLE public.agent_cash_deposit_lots ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS acdl_pdg_read ON public.agent_cash_deposit_lots;
CREATE POLICY acdl_pdg_read ON public.agent_cash_deposit_lots FOR SELECT TO authenticated
  USING (public.is_admin_or_pdg()
         OR agent_id IN (SELECT id FROM public.agents_management WHERE user_id = auth.uid()));
-- Écriture : service_role uniquement (via les triggers SECURITY DEFINER). Aucune policy write.
REVOKE ALL ON public.agent_cash_deposit_lots FROM anon, authenticated;
GRANT SELECT ON public.agent_cash_deposit_lots TO authenticated;

-- ── 3) Trigger DÉPÔT : créer le lot à chaque client_credit de dépôt ─────────
-- Hook fiable (client_credit inséré exactement une fois par dépôt ; sur rejeu
-- idempotent la fonction retourne AVANT d'insérer des legs → pas de doublon).
CREATE OR REPLACE FUNCTION public.agent_cash_create_deposit_lot()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.agent_cash_deposit_lots
    (agent_id, client_user_id, parent_tx_id, amount_initial, amount_remaining, currency, created_at)
  VALUES (NEW.agent_id, NEW.client_user_id, NEW.parent_tx_id, NEW.amount, NEW.amount, NEW.currency, NEW.created_at)
  ON CONFLICT (parent_tx_id) DO NOTHING;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.agent_cash_create_deposit_lot() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_acash_create_deposit_lot ON public.agent_cash_ledger;
CREATE TRIGGER trg_acash_create_deposit_lot
  AFTER INSERT ON public.agent_cash_ledger
  FOR EACH ROW WHEN (NEW.operation = 'deposit' AND NEW.leg = 'client_credit')
  EXECUTE FUNCTION public.agent_cash_create_deposit_lot();

-- ── 4) Trigger RETRAIT : consommer les lots FIFO + créditer les agents de dépôt ─
-- Se déclenche quand le retrait est FINALISÉ (result passe de NULL à non-NULL) :
-- à ce moment NEW.fee (GNF), NEW.amount (devise client), NEW.parent_tx_id sont posés,
-- le coffre PDG a déjà reçu le frais complet → on lui débite la part dépôt.
CREATE OR REPLACE FUNCTION public.agent_cash_settle_deposit_lots()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_client_cur text;
  v_d_share    numeric;
  v_pdg_wallet bigint;
  v_cap        numeric;
  v_remaining  numeric;          -- montant retiré restant à couvrir (devise client)
  v_take       numeric;
  v_share_gnf  numeric;
  v_lot        RECORD;
  v_dep_uid    uuid;
  v_dep_aw_id  bigint; v_dep_aw_cur text;
  v_fx         jsonb; v_dep_amt numeric;
  v_day        numeric; v_pending boolean; v_reason text; v_susp boolean;
BEGIN
  -- Frais nul → rien à partager. (min 1000 fait qu'un frais réel est quasi toujours > 0.)
  IF COALESCE(NEW.fee, 0) <= 0 OR NEW.amount IS NULL OR NEW.amount <= 0 THEN RETURN NEW; END IF;

  -- Devise du CLIENT = celle du leg client_debit de ce retrait ; part dépôt depuis la grille.
  SELECT currency INTO v_client_cur FROM public.agent_cash_ledger
    WHERE parent_tx_id = NEW.parent_tx_id AND leg = 'client_debit' LIMIT 1;
  v_client_cur := COALESCE(v_client_cur, 'GNF');
  v_d_share := COALESCE((public._acash_currency_rules(v_client_cur)->>'d_share')::numeric, 0);
  IF v_d_share <= 0 THEN RETURN NEW; END IF;

  v_pdg_wallet := public.get_pdg_gnf_wallet_id();
  v_cap := (public.agent_cash_active_config()).daily_commission_cap_per_agent;
  v_remaining := NEW.amount;

  FOR v_lot IN
    SELECT * FROM public.agent_cash_deposit_lots
    WHERE client_user_id = NEW.client_user_id AND currency = v_client_cur AND amount_remaining > 0
    ORDER BY created_at ASC, id ASC
    FOR UPDATE
  LOOP
    EXIT WHEN v_remaining <= 0;
    v_take := least(v_lot.amount_remaining, v_remaining);
    UPDATE public.agent_cash_deposit_lots SET amount_remaining = amount_remaining - v_take WHERE id = v_lot.id;
    v_remaining := v_remaining - v_take;

    -- Part dépôt (GNF) pour ce lot = frais_gnf × d_share% × (part couverte / montant retiré).
    v_share_gnf := round(NEW.fee * v_d_share / 100.0 * v_take / NEW.amount);
    IF v_share_gnf <= 0 THEN CONTINUE; END IF;

    SELECT user_id INTO v_dep_uid FROM public.agents_management WHERE id = v_lot.agent_id;
    SELECT wallet_id, currency INTO v_dep_aw_id, v_dep_aw_cur FROM public._acash_agent_wallet(v_dep_uid);
    IF v_dep_aw_id IS NULL THEN CONTINUE; END IF;

    v_fx := public._acash_fx(v_share_gnf, 'GNF', v_dep_aw_cur);
    v_dep_amt := (v_fx->>'converted')::numeric;

    -- Plafond journalier / suspension de l'AGENT DE DÉPÔT → bascule en attente.
    SELECT COALESCE(sum(agent_share),0) INTO v_day FROM public.agent_cash_operations
      WHERE agent_id = v_lot.agent_id AND operation IN ('deposit','withdrawal') AND created_at::date = now()::date;
    SELECT cash_agent_suspended INTO v_susp FROM public.agents_management WHERE id = v_lot.agent_id;
    v_pending := false; v_reason := NULL;
    IF v_susp THEN v_pending := true; v_reason := 'agent_suspendu';
    ELSIF (v_day + v_share_gnf) > v_cap THEN v_pending := true; v_reason := 'plafond_journalier';
    END IF;

    IF v_pending THEN
      INSERT INTO public.agent_commission_pending (agent_id, amount, reason, source_parent_tx_id)
      VALUES (v_lot.agent_id, v_share_gnf, v_reason, NEW.parent_tx_id);
      INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency, status)
      VALUES (NEW.parent_tx_id, 'withdrawal', 'deposit_agent_deferred_credit', v_lot.agent_id, NEW.client_user_id, v_dep_amt, v_dep_aw_cur, 'pending');
    ELSE
      -- Débit coffre PDG (il a le frais complet) → crédit agent de dépôt dans SA devise.
      PERFORM public._acash_debit_wallet(v_pdg_wallet, v_share_gnf, 'PDG_INSUFFISANT');
      PERFORM public._acash_credit_wallet(v_dep_aw_id, v_dep_amt);
      INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency)
      VALUES (NEW.parent_tx_id, 'withdrawal', 'pdg_commission_debit', v_lot.agent_id, NEW.client_user_id, v_share_gnf, 'GNF');
      INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency, fx_rate, fx_rate_at, fx_source)
      VALUES (NEW.parent_tx_id, 'withdrawal', 'deposit_agent_deferred_credit', v_lot.agent_id, NEW.client_user_id, v_dep_amt, v_dep_aw_cur,
              (v_fx->>'rate')::numeric, (v_fx->>'rate_at')::timestamptz, v_fx->>'source');
    END IF;
  END LOOP;

  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.agent_cash_settle_deposit_lots() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_acash_settle_deposit_lots ON public.agent_cash_operations;
CREATE TRIGGER trg_acash_settle_deposit_lots
  AFTER UPDATE OF result ON public.agent_cash_operations
  FOR EACH ROW
  WHEN (NEW.operation = 'withdrawal' AND OLD.result IS NULL AND NEW.result IS NOT NULL)
  EXECUTE FUNCTION public.agent_cash_settle_deposit_lots();

-- ── 5) Reconstruction des lots historiques (FIFO rejoué) — À LANCER UNE FOIS ──
-- AUCUN paiement rétroactif : on ne fait que recréer l'état des lots (dépôts non
-- encore consommés par les retraits passés). Idempotent (skip si déjà peuplé).
CREATE OR REPLACE FUNCTION public.agent_cash_rebuild_deposit_lots()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_created int := 0; v_ev RECORD; v_wd numeric; v_take numeric; v_lot RECORD;
BEGIN
  IF EXISTS (SELECT 1 FROM public.agent_cash_deposit_lots) THEN
    RETURN jsonb_build_object('skipped', true, 'reason', 'already_populated');
  END IF;
  FOR v_ev IN
    SELECT o.operation, o.agent_id, o.client_user_id, o.amount, o.parent_tx_id, o.created_at,
           COALESCE((SELECT l.currency FROM public.agent_cash_ledger l
                     WHERE l.parent_tx_id = o.parent_tx_id AND l.leg IN ('client_credit','client_debit') LIMIT 1), 'GNF') AS ccy
    FROM public.agent_cash_operations o
    WHERE o.operation IN ('deposit','withdrawal') AND o.result IS NOT NULL
    ORDER BY o.created_at ASC, o.parent_tx_id
  LOOP
    IF v_ev.operation = 'deposit' THEN
      INSERT INTO public.agent_cash_deposit_lots
        (agent_id, client_user_id, parent_tx_id, amount_initial, amount_remaining, currency, created_at)
      VALUES (v_ev.agent_id, v_ev.client_user_id, v_ev.parent_tx_id, v_ev.amount, v_ev.amount, v_ev.ccy, v_ev.created_at)
      ON CONFLICT (parent_tx_id) DO NOTHING;
      v_created := v_created + 1;
    ELSE
      v_wd := v_ev.amount;
      FOR v_lot IN SELECT * FROM public.agent_cash_deposit_lots
        WHERE client_user_id = v_ev.client_user_id AND currency = v_ev.ccy AND amount_remaining > 0
        ORDER BY created_at ASC, id ASC LOOP
        EXIT WHEN v_wd <= 0;
        v_take := least(v_lot.amount_remaining, v_wd);
        UPDATE public.agent_cash_deposit_lots SET amount_remaining = amount_remaining - v_take WHERE id = v_lot.id;
        v_wd := v_wd - v_take;
      END LOOP;
    END IF;
  END LOOP;
  DELETE FROM public.agent_cash_deposit_lots WHERE amount_remaining <= 0;
  RETURN jsonb_build_object('lots_created', v_created,
    'active_lots', (SELECT count(*) FROM public.agent_cash_deposit_lots),
    'total_remaining', (SELECT COALESCE(sum(amount_remaining),0) FROM public.agent_cash_deposit_lots));
END $$;
REVOKE ALL ON FUNCTION public.agent_cash_rebuild_deposit_lots() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.agent_cash_rebuild_deposit_lots() TO service_role;

-- Après application : SELECT public.agent_cash_rebuild_deposit_lots();  (une seule fois)
