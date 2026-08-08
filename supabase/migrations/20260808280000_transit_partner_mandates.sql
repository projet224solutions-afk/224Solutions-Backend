-- ============================================================================
-- 🔐 MANDAT DE PRÉLÈVEMENT — prélever sur le wallet d'autrui, sous consentement
-- ----------------------------------------------------------------------------
-- C'est la fonctionnalité la plus sensible du réseau : le transitaire prélève sur
-- le compte de son partenaire. Tout le fichier n'existe que pour UNE raison —
-- rendre ce prélèvement IMPOSSIBLE hors du consentement explicite du propriétaire
-- du wallet, borné et révocable.
--
-- AUCUN CIRCUIT D'ARGENT NOUVEAU : le prélèvement appelle le primitif canonique
-- `process_wallet_transfer_with_fees_core`, avec `p_commission_bearer='recipient'`
-- (arbitrage PDG). Le partenaire est débité du montant EXACT qu'il a autorisé ;
-- les frais sortent de la part du transitaire, qui est l'initiateur. Le mandat
-- n'est qu'un CONSENTEMENT VÉRIFIÉ posé devant le flux normal.
--
-- ASYMÉTRIE VOULUE : le mandat est créé par le PARTENAIRE seul (propriétaire du
-- wallet débité) et révoqué par lui à tout instant. Le transitaire peut le
-- demander, jamais le créer — sinon le « consentement » serait décidé par celui
-- qui en profite.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.transit_partner_mandates (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  partnership_id  uuid NOT NULL REFERENCES public.transit_partners(id) ON DELETE CASCADE,
  granted_by      uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE, -- propriétaire du wallet
  granted_to      uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE, -- bénéficiaire du droit
  -- Bornes exprimées dans la devise du wallet DÉBITÉ : le partenaire raisonne
  -- dans sa monnaie, pas dans celle du transitaire.
  currency        text NOT NULL,
  max_per_operation numeric NOT NULL CHECK (max_per_operation > 0),
  max_per_period    numeric NOT NULL CHECK (max_per_period > 0),
  period_kind     text NOT NULL DEFAULT 'month' CHECK (period_kind IN ('month')),
  expires_at      timestamptz,
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'revoked', 'expired')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  revoked_at      timestamptz,
  CONSTRAINT mandate_not_self CHECK (granted_by <> granted_to),
  -- Un plafond par opération supérieur au plafond de période serait un piège :
  -- l'utilisateur croirait borner deux fois, il ne bornerait qu'une.
  CONSTRAINT mandate_caps_coherent CHECK (max_per_operation <= max_per_period)
);

-- UN SEUL mandat vivant par couple : sinon révoquer l'un laisserait l'autre actif,
-- et la révocation ne voudrait rien dire.
CREATE UNIQUE INDEX IF NOT EXISTS uq_mandate_active_per_couple
  ON public.transit_partner_mandates (granted_by, granted_to)
  WHERE status = 'active';

-- ── Événements APPEND-ONLY : l'historique d'un prélèvement est une preuve ──
CREATE TABLE IF NOT EXISTS public.transit_mandate_events (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  mandate_id  uuid NOT NULL REFERENCES public.transit_partner_mandates(id) ON DELETE CASCADE,
  event_type  text NOT NULL CHECK (event_type IN ('created', 'pull', 'revoked', 'refused')),
  amount      numeric,
  currency    text,
  rate_used   numeric,
  credited    numeric,
  reason      text,
  actor_id    uuid NOT NULL REFERENCES public.profiles(id),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_mandate_events ON public.transit_mandate_events (mandate_id, created_at DESC);
CREATE OR REPLACE RULE mandate_events_no_update AS ON UPDATE TO public.transit_mandate_events DO INSTEAD NOTHING;
CREATE OR REPLACE RULE mandate_events_no_delete AS ON DELETE TO public.transit_mandate_events DO INSTEAD NOTHING;

ALTER TABLE public.transit_partner_mandates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.transit_mandate_events   ENABLE ROW LEVEL SECURITY;

-- Les DEUX parties lisent : le partenaire doit voir où va son argent sans avoir
-- à le demander ; le transitaire doit voir ses droits.
DROP POLICY IF EXISTS mandates_read ON public.transit_partner_mandates;
CREATE POLICY mandates_read ON public.transit_partner_mandates FOR SELECT TO authenticated
  USING (granted_by = (SELECT auth.uid()) OR granted_to = (SELECT auth.uid()));

DROP POLICY IF EXISTS mandate_events_read ON public.transit_mandate_events;
CREATE POLICY mandate_events_read ON public.transit_mandate_events FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.transit_partner_mandates m WHERE m.id = mandate_id
                 AND (m.granted_by = (SELECT auth.uid()) OR m.granted_to = (SELECT auth.uid()))));
-- Aucune policy d'écriture : tout passe par les RPC.

-- ── OCTROI — par le PARTENAIRE uniquement ─────────────────────────────────
CREATE OR REPLACE FUNCTION public.transit_mandate_grant(
  p_partnership_id uuid, p_max_per_operation numeric, p_max_per_period numeric,
  p_confirm_amount numeric, p_expires_at timestamptz DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); v_tp record; v_cur text; v_id uuid; v_autre uuid;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'non authentifié'); END IF;

  SELECT * INTO v_tp FROM public.transit_partners WHERE id = p_partnership_id;
  IF NOT FOUND OR v_tp.status <> 'active' THEN
    RETURN jsonb_build_object('success', false, 'error', 'partenariat non actif', 'error_code', 'NOT_ACTIVE');
  END IF;
  -- Le mandant DOIT être partie au partenariat, et le bénéficiaire est l'autre.
  IF v_uid NOT IN (v_tp.owner_transitaire_id, v_tp.partner_transitaire_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'forbidden', 'error_code', 'FORBIDDEN');
  END IF;
  v_autre := CASE WHEN v_uid = v_tp.owner_transitaire_id THEN v_tp.partner_transitaire_id
                  ELSE v_tp.owner_transitaire_id END;
  IF v_autre IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'partenaire inconnu'); END IF;

  -- Confirmation forte : le plafond doit être RE-SAISI à l'identique. Un clic seul
  -- ne vaut pas consentement quand il ouvre l'accès à un compte.
  IF p_confirm_amount IS DISTINCT FROM p_max_per_operation THEN
    RETURN jsonb_build_object('success', false, 'error', 'confirmation du plafond incorrecte',
                              'error_code', 'CONFIRM_MISMATCH');
  END IF;
  IF COALESCE(p_max_per_operation, 0) <= 0 OR COALESCE(p_max_per_period, 0) <= 0
     OR p_max_per_operation > p_max_per_period THEN
    RETURN jsonb_build_object('success', false, 'error', 'plafonds incohérents', 'error_code', 'BAD_CAPS');
  END IF;

  SELECT currency INTO v_cur FROM public.wallets WHERE user_id = v_uid ORDER BY created_at LIMIT 1;
  IF v_cur IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'wallet introuvable'); END IF;

  -- Un mandat actif existant est RÉVOQUÉ puis remplacé : deux mandats vivants
  -- rendraient les plafonds inopérants (on cumulerait deux autorisations).
  UPDATE public.transit_partner_mandates
  SET status = 'revoked', revoked_at = now()
  WHERE granted_by = v_uid AND granted_to = v_autre AND status = 'active';

  INSERT INTO public.transit_partner_mandates
    (partnership_id, granted_by, granted_to, currency, max_per_operation, max_per_period, expires_at)
  VALUES (p_partnership_id, v_uid, v_autre, v_cur, p_max_per_operation, p_max_per_period, p_expires_at)
  RETURNING id INTO v_id;

  INSERT INTO public.transit_mandate_events (mandate_id, event_type, amount, currency, actor_id)
  VALUES (v_id, 'created', p_max_per_operation, v_cur, v_uid);

  INSERT INTO public.notifications (user_id, title, message, type)
  VALUES (v_autre, 'Mandat de prélèvement accordé',
          'Votre partenaire vous autorise à prélever jusqu''à ' || p_max_per_operation::text || ' ' || v_cur
          || ' par opération.', 'success');

  RETURN jsonb_build_object('success', true, 'mandate_id', v_id, 'currency', v_cur);
END; $$;

-- ── RÉVOCATION — par le mandant, effet immédiat ───────────────────────────
CREATE OR REPLACE FUNCTION public.transit_mandate_revoke(p_mandate_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); v_m record;
BEGIN
  SELECT * INTO v_m FROM public.transit_partner_mandates WHERE id = p_mandate_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'mandat introuvable'); END IF;
  -- Le bénéficiaire peut aussi renoncer ; seul un tiers est refusé.
  IF v_uid NOT IN (v_m.granted_by, v_m.granted_to) THEN
    RETURN jsonb_build_object('success', false, 'error', 'forbidden', 'error_code', 'FORBIDDEN');
  END IF;
  IF v_m.status <> 'active' THEN RETURN jsonb_build_object('success', true, 'skipped', true); END IF;

  UPDATE public.transit_partner_mandates SET status = 'revoked', revoked_at = now() WHERE id = p_mandate_id;
  INSERT INTO public.transit_mandate_events (mandate_id, event_type, actor_id) VALUES (p_mandate_id, 'revoked', v_uid);
  INSERT INTO public.notifications (user_id, title, message, type)
  SELECT u, 'Mandat de prélèvement révoqué', 'Le mandat a pris fin. Plus aucun prélèvement n''est possible.', 'warning'
  FROM unnest(ARRAY[v_m.granted_by, v_m.granted_to]) u WHERE u <> v_uid;

  RETURN jsonb_build_object('success', true, 'status', 'revoked');
END; $$;

-- Révoquer le PARTENARIAT révoque ses mandats : un consentement ne survit pas
-- au lien qui le fondait.
CREATE OR REPLACE FUNCTION public.revoke_mandates_on_partnership_revoke()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.status = 'revoked' AND OLD.status IS DISTINCT FROM 'revoked' THEN
    UPDATE public.transit_partner_mandates
    SET status = 'revoked', revoked_at = now()
    WHERE partnership_id = NEW.id AND status = 'active';
  END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS trg_revoke_mandates ON public.transit_partners;
CREATE TRIGGER trg_revoke_mandates AFTER UPDATE OF status ON public.transit_partners
  FOR EACH ROW EXECUTE FUNCTION public.revoke_mandates_on_partnership_revoke();

-- ── LE PRÉLÈVEMENT ────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.transit_mandate_pull(
  p_mandate_id uuid, p_amount numeric, p_reason text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid uuid := auth.uid(); v_m record; v_tp record;
  v_cumul numeric; v_solde numeric; v_code_src text; v_code_dst text; v_res json;
BEGIN
  SELECT * INTO v_m FROM public.transit_partner_mandates WHERE id = p_mandate_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'mandat introuvable'); END IF;
  IF v_m.granted_to <> v_uid THEN
    RETURN jsonb_build_object('success', false, 'error', 'forbidden', 'error_code', 'FORBIDDEN');
  END IF;

  -- Chaque garde est FAIL-CLOSED et tracée : un refus laisse une trace, sinon
  -- une tentative répétée serait invisible.
  IF v_m.status <> 'active' THEN
    INSERT INTO public.transit_mandate_events (mandate_id, event_type, amount, reason, actor_id)
    VALUES (p_mandate_id, 'refused', p_amount, 'mandat non actif', v_uid);
    RETURN jsonb_build_object('success', false, 'error', 'mandat non actif', 'error_code', 'MANDATE_REVOKED');
  END IF;
  IF v_m.expires_at IS NOT NULL AND v_m.expires_at < now() THEN
    UPDATE public.transit_partner_mandates SET status = 'expired' WHERE id = p_mandate_id;
    RETURN jsonb_build_object('success', false, 'error', 'mandat expiré', 'error_code', 'MANDATE_EXPIRED');
  END IF;

  SELECT * INTO v_tp FROM public.transit_partners WHERE id = v_m.partnership_id;
  IF v_tp.status <> 'active' THEN
    RETURN jsonb_build_object('success', false, 'error', 'partenariat non actif', 'error_code', 'PARTNERSHIP_INACTIVE');
  END IF;

  IF COALESCE(p_amount, 0) <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'montant invalide');
  END IF;
  IF p_amount > v_m.max_per_operation THEN
    INSERT INTO public.transit_mandate_events (mandate_id, event_type, amount, currency, reason, actor_id)
    VALUES (p_mandate_id, 'refused', p_amount, v_m.currency, 'plafond par opération', v_uid);
    RETURN jsonb_build_object('success', false, 'error', 'plafond par opération dépassé',
                              'error_code', 'OVER_CAP_OPERATION', 'plafond', v_m.max_per_operation);
  END IF;

  -- Cumul de la PÉRIODE COURANTE, calculé sur les événements (source unique).
  SELECT COALESCE(SUM(amount), 0) INTO v_cumul
  FROM public.transit_mandate_events
  WHERE mandate_id = p_mandate_id AND event_type = 'pull'
    AND created_at >= date_trunc('month', now());
  IF v_cumul + p_amount > v_m.max_per_period THEN
    INSERT INTO public.transit_mandate_events (mandate_id, event_type, amount, currency, reason, actor_id)
    VALUES (p_mandate_id, 'refused', p_amount, v_m.currency, 'plafond de période', v_uid);
    RETURN jsonb_build_object('success', false, 'error', 'plafond de période dépassé',
                              'error_code', 'OVER_CAP_PERIOD', 'deja_preleve', v_cumul, 'plafond', v_m.max_per_period);
  END IF;

  SELECT balance INTO v_solde FROM public.wallets
  WHERE user_id = v_m.granted_by AND currency = v_m.currency FOR UPDATE;
  IF COALESCE(v_solde, 0) < p_amount THEN
    RETURN jsonb_build_object('success', false, 'error', 'solde insuffisant', 'error_code', 'INSUFFICIENT_FUNDS');
  END IF;

  SELECT public_id INTO v_code_src FROM public.profiles WHERE id = v_m.granted_by;
  SELECT public_id INTO v_code_dst FROM public.profiles WHERE id = v_m.granted_to;
  IF v_code_src IS NULL OR v_code_dst IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'identifiant public manquant', 'error_code', 'NO_PUBLIC_ID');
  END IF;

  -- 💸 LE MÊME PRIMITIF QUE TOUT LE MONDE, avec le porteur de commission arbitré.
  v_res := public.process_wallet_transfer_with_fees_core(
    v_code_src, v_code_dst, p_amount, v_m.currency::varchar,
    'Prélèvement sous mandat' || COALESCE(' — ' || p_reason, ''), 'recipient');

  IF COALESCE((v_res->>'success')::boolean, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('success', false, 'error', COALESCE(v_res->>'error', 'transfert refusé'),
                              'error_code', 'TRANSFER_FAILED');
  END IF;

  INSERT INTO public.transit_mandate_events
    (mandate_id, event_type, amount, currency, rate_used, credited, reason, actor_id)
  VALUES (p_mandate_id, 'pull', p_amount, v_m.currency,
          (v_res->>'rate_used')::numeric, (v_res->>'amount_received')::numeric, p_reason, v_uid);

  SELECT balance INTO v_solde FROM public.wallets WHERE user_id = v_m.granted_by AND currency = v_m.currency;

  -- Transparence : c'est SON argent, il l'apprend immédiatement et sans demander.
  INSERT INTO public.notifications (user_id, title, message, type) VALUES
    (v_m.granted_by, 'Prélèvement sur votre compte',
     'Prélèvement de ' || p_amount::text || ' ' || v_m.currency
     || COALESCE(' — ' || p_reason, '') || '. Solde restant : ' || v_solde::text || ' ' || v_m.currency || '.', 'warning'),
    (v_m.granted_to, 'Prélèvement effectué',
     'Vous avez prélevé ' || p_amount::text || ' ' || v_m.currency || '. Reçu : '
     || COALESCE(v_res->>'amount_received', '?') || ' (commission à votre charge).', 'success');

  RETURN jsonb_build_object('success', true, 'mandate_id', p_mandate_id, 'debite', p_amount,
                            'devise', v_m.currency, 'credite', (v_res->>'amount_received')::numeric,
                            'frais', (v_res->>'fee_amount')::numeric,
                            'solde_restant', v_solde, 'transaction_id', v_res->>'transaction_id');
END; $$;

REVOKE ALL ON FUNCTION public.transit_mandate_grant(uuid, numeric, numeric, numeric, timestamptz) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.transit_mandate_revoke(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.transit_mandate_pull(uuid, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.transit_mandate_grant(uuid, numeric, numeric, numeric, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transit_mandate_revoke(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transit_mandate_pull(uuid, numeric, text) TO authenticated;

SELECT 'Mandat de prélèvement : octroi, révocation, prélèvement borné — primitif canonique, bearer recipient.' AS status;
