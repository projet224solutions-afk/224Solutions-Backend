-- ============================================================================
-- VERROU DÉPÔTS EN BASE (Phase 4) — aucun crédit sans ligne de paiement encaissée
-- ----------------------------------------------------------------------------
-- Défense en profondeur : même si une route/edge fautive appelait un crédit, la base
-- REFUSE tout crédit de dépôt qui n'est pas adossé à une ligne `payment_transactions`
-- status='completed' non encore consommée. Un seul helper de crédit-après-paiement
-- (`settle_deposit`) partagé par TOUS les webhooks (Stripe / ChapChapPay / Djomy / PayPal).
-- ============================================================================

-- 1) Ledger canonique des paiements de dépôt (argent entrant de l'extérieur)
CREATE TABLE IF NOT EXISTS public.payment_transactions (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider      text NOT NULL,                 -- 'stripe' | 'chapchappay' | 'djomy' | 'paypal'
  provider_ref  text NOT NULL,                 -- PI id / txid CCP / capture id PayPal (idempotence)
  user_id       uuid NOT NULL,
  amount        numeric NOT NULL CHECK (amount > 0),
  currency      text NOT NULL DEFAULT 'GNF',
  status        text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','completed','failed')),
  credited_at   timestamptz,                   -- NULL tant que non consommée (crédit UNIQUE)
  description   text,
  metadata      jsonb DEFAULT '{}'::jsonb,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  -- Une même preuve prestataire ne peut créditer qu'une fois (Phase 4.2).
  CONSTRAINT payment_transactions_provider_ref_uk UNIQUE (provider, provider_ref)
);
CREATE INDEX IF NOT EXISTS idx_payment_transactions_user ON public.payment_transactions(user_id);
CREATE INDEX IF NOT EXISTS idx_payment_transactions_status ON public.payment_transactions(status) WHERE status = 'completed';

ALTER TABLE public.payment_transactions ENABLE ROW LEVEL SECURITY;
-- Lecture : le propriétaire voit ses paiements ; PDG/admin voient tout. Écriture = service_role
-- uniquement (aucune policy INSERT/UPDATE pour anon/authenticated → PostgREST ne peut pas écrire).
DROP POLICY IF EXISTS pt_owner_read ON public.payment_transactions;
CREATE POLICY pt_owner_read ON public.payment_transactions
  FOR SELECT TO authenticated USING (user_id = auth.uid());
DROP POLICY IF EXISTS pt_admin_read ON public.payment_transactions;
CREATE POLICY pt_admin_read ON public.payment_transactions
  FOR SELECT TO authenticated USING (public.is_admin_or_pdg());

-- 2) LE VERROU : crédite un dépôt UNIQUEMENT depuis une ligne completed non consommée.
CREATE OR REPLACE FUNCTION public.credit_deposit_from_payment(p_payment_transaction_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_pt        record;
  v_res       jsonb;
  v_credited  numeric;
  v_quar      numeric;
  v_wallet_id bigint;
  v_cur       text;
  v_tx_id     text;
BEGIN
  SELECT * INTO v_pt FROM public.payment_transactions WHERE id = p_payment_transaction_id FOR UPDATE;

  -- Aucune ligne payée valide → REFUS (jamais de crédit « libre »).
  IF NOT FOUND THEN
    RAISE EXCEPTION 'NO_SETTLED_PAYMENT' USING DETAIL = 'payment_transaction introuvable';
  END IF;
  IF v_pt.status <> 'completed' THEN
    RAISE EXCEPTION 'NO_SETTLED_PAYMENT' USING DETAIL = 'statut=' || COALESCE(v_pt.status, 'NULL');
  END IF;

  -- Déjà consommée → no-op idempotent (anti double-crédit sur rejeu webhook).
  IF v_pt.credited_at IS NOT NULL THEN
    RETURN jsonb_build_object('success', true, 'skipped', true, 'already_credited', true,
      'payment_transaction_id', p_payment_transaction_id);
  END IF;

  -- Crédit AML atomique (plafond + quarantaine + idempotence par source_txn_id = id de paiement).
  v_res := public.credit_user_wallet_safe(v_pt.user_id, v_pt.amount, v_pt.currency, 'deposit',
                                          p_payment_transaction_id::text);
  v_credited  := COALESCE((v_res->>'credited')::numeric, 0);
  v_quar      := COALESCE((v_res->>'quarantined')::numeric, 0);
  v_wallet_id := (v_res->>'wallet_id')::bigint;
  v_cur       := COALESCE(v_res->>'currency', v_pt.currency, 'GNF');

  -- Ledger d'historique (sauf si credit_user_wallet_safe a déjà tout skippé par idempotence).
  IF NOT COALESCE((v_res->>'skipped')::boolean, false) THEN
    v_tx_id := public.generate_transaction_id();
    INSERT INTO public.wallet_transactions (
      transaction_id, receiver_wallet_id, receiver_user_id,
      transaction_type, amount, net_amount, status, currency, description, metadata)
    VALUES (
      v_tx_id, v_wallet_id, v_pt.user_id,
      'deposit'::public.transaction_type, v_pt.amount, v_pt.amount, 'completed', v_cur,
      COALESCE(v_pt.description, 'Dépôt ' || v_pt.provider),
      jsonb_build_object('provider', v_pt.provider, 'provider_ref', v_pt.provider_ref,
                         'payment_transaction_id', p_payment_transaction_id,
                         'credited', v_credited, 'quarantined', v_quar));
  END IF;

  -- Consommation UNIQUE de la ligne de paiement.
  UPDATE public.payment_transactions SET credited_at = now(), updated_at = now()
   WHERE id = p_payment_transaction_id;

  RETURN jsonb_build_object('success', true, 'credited', v_credited, 'quarantined', v_quar,
    'wallet_id', v_wallet_id, 'currency', v_cur, 'payment_transaction_id', p_payment_transaction_id);
END;
$function$;

-- 3) LE HELPER UNIQUE partagé par tous les webhooks : pose/complète la ligne (concordance
--    montant obligatoire) puis crédite via le verrou. Appelé APRÈS vérif signature+statut.
CREATE OR REPLACE FUNCTION public.settle_deposit(
  p_provider text, p_provider_ref text, p_user_id uuid,
  p_amount numeric, p_currency text DEFAULT 'GNF', p_description text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_id       uuid;
  v_existing record;
BEGIN
  IF p_provider IS NULL OR p_provider_ref IS NULL OR p_user_id IS NULL OR COALESCE(p_amount, 0) <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'PARAMS_INVALIDES');
  END IF;

  SELECT * INTO v_existing FROM public.payment_transactions
   WHERE provider = p_provider AND provider_ref = p_provider_ref FOR UPDATE;

  IF FOUND THEN
    -- Concordance montant (Phase 3.4c) : un webhook dont le montant diffère de la ligne
    -- d'initiation est rejeté — pas de crédit « ajusté ».
    IF v_existing.amount <> p_amount THEN
      RAISE EXCEPTION 'AMOUNT_MISMATCH' USING DETAIL =
        format('attendu %s, reçu %s', v_existing.amount, p_amount);
    END IF;
    v_id := v_existing.id;
    IF v_existing.status <> 'completed' THEN
      UPDATE public.payment_transactions SET status = 'completed', updated_at = now() WHERE id = v_id;
    END IF;
  ELSE
    INSERT INTO public.payment_transactions (provider, provider_ref, user_id, amount, currency, status, description)
    VALUES (p_provider, p_provider_ref, p_user_id, p_amount, COALESCE(p_currency, 'GNF'), 'completed', p_description)
    RETURNING id INTO v_id;
  END IF;

  RETURN public.credit_deposit_from_payment(v_id);
END;
$function$;

-- 4) GRANTs (Phase 4.3) : crédit-dépôt exécutable UNIQUEMENT par service_role (webhooks).
--    Aucun chemin RPC de crédit-dépôt pour un utilisateur `authenticated`.
REVOKE ALL ON FUNCTION public.credit_deposit_from_payment(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.credit_deposit_from_payment(uuid) TO service_role;
REVOKE ALL ON FUNCTION public.settle_deposit(text, text, uuid, numeric, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.settle_deposit(text, text, uuid, numeric, text, text) TO service_role;
