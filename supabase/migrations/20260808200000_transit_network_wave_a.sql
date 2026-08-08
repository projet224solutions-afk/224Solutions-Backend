-- ============================================================================
-- 🌍 RÉSEAU TRANSITAIRE MULTI-PAYS — VAGUE A : partenariats + colis
-- ----------------------------------------------------------------------------
-- CAS RÉEL (PDG) : un transitaire réceptionne les colis EN CHINE ; son PARTENAIRE
-- en Guinée gère réception, livraison et encaissement locaux. Chacun doit opérer
-- chez lui, et l'owner doit garder un œil sur son entreprise.
--
-- CE FICHIER POSE LA VAGUE A : le lien de partenariat (4.1) et la granularité qui
-- manquait à l'ERP — le COLIS (4.2). Le partage de dossiers et la vue « Mon réseau »
-- sont la vague B ; la RLS posée ici est donc volontairement OWNER-ONLY sur les colis :
-- élargir aux partenaires sans la table de partage serait ouvrir un accès sans le
-- contrôle qui va avec.
--
-- ⚠️ AUCUN MOUVEMENT D'ARGENT ICI. « Marquer payé » est un REGISTRE d'encaissement
-- cash au comptoir du partenaire — il n'écrit dans aucun wallet et ne crée aucune
-- ligne de transaction. Si le paiement passe par le wallet 224, il suit le flux
-- normal et le registre le reflétera (vague B) : jamais deux circuits d'argent.
--
-- RÉUTILISATION : `generate_unique_barcode` (codes scannables, déjà utilisée par le
-- POS/billetterie) et le patron append-only de `transit_file_events`.
-- ============================================================================

-- ── 1) PARTENARIATS ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.transit_partners (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_transitaire_id  uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  partner_transitaire_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  -- Rôle du PARTENAIRE dans la chaîne (pas celui de l'owner).
  partner_role          text NOT NULL CHECK (partner_role IN ('agent_destination', 'agent_origine')),
  status                text NOT NULL DEFAULT 'invited' CHECK (status IN ('invited', 'active', 'revoked')),
  -- Invitation par code court OU email : le réseau est un argument d'acquisition —
  -- on invite un correspondant qui n'a pas encore de compte.
  invite_code           text UNIQUE,
  invited_email         text,
  invited_at            timestamptz NOT NULL DEFAULT now(),
  accepted_at           timestamptz,
  revoked_at            timestamptz,
  created_by            uuid NOT NULL REFERENCES public.profiles(id),
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  -- Un partenaire ne peut pas être son propre partenaire.
  CONSTRAINT transit_partners_not_self CHECK (owner_transitaire_id IS DISTINCT FROM partner_transitaire_id)
);

-- Un SEUL partenariat vivant par couple : sans cela, révoquer l'un laisserait
-- l'autre ouvert et la révocation ne voudrait plus rien dire.
CREATE UNIQUE INDEX IF NOT EXISTS uq_transit_partners_alive
  ON public.transit_partners (owner_transitaire_id, partner_transitaire_id)
  WHERE status IN ('invited', 'active') AND partner_transitaire_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_transit_partners_owner ON public.transit_partners (owner_transitaire_id, status);
CREATE INDEX IF NOT EXISTS idx_transit_partners_partner ON public.transit_partners (partner_transitaire_id, status);

-- ── 2) COLIS ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.transit_parcels (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  file_id          uuid NOT NULL REFERENCES public.transit_files(id) ON DELETE CASCADE,
  parcel_code      text NOT NULL UNIQUE,
  description      text,
  weight_kg        numeric CHECK (weight_kg IS NULL OR weight_kg >= 0),
  volume_cbm       numeric CHECK (volume_cbm IS NULL OR volume_cbm >= 0),
  declared_value   numeric CHECK (declared_value IS NULL OR declared_value >= 0),
  declared_currency text,
  status           text NOT NULL DEFAULT 'recu_origine'
                     CHECK (status IN ('recu_origine', 'embarque', 'arrive_destination', 'livre')),
  payment_status   text NOT NULL DEFAULT 'non_paye'
                     CHECK (payment_status IN ('non_paye', 'paye', 'partiel')),
  amount_due       numeric NOT NULL DEFAULT 0 CHECK (amount_due >= 0),
  amount_paid      numeric NOT NULL DEFAULT 0 CHECK (amount_paid >= 0),
  -- Devise du montant dû : celle du PAYS où l'encaissement a lieu. Jamais de somme
  -- inter-devises en aval — les compteurs agrègent PAR devise.
  amount_currency  text NOT NULL DEFAULT 'GNF',
  collected_by     uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  collected_at     timestamptz,
  created_by       uuid NOT NULL REFERENCES public.profiles(id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_transit_parcels_file ON public.transit_parcels (file_id, status);
CREATE INDEX IF NOT EXISTS idx_transit_parcels_payment ON public.transit_parcels (payment_status);

-- ── 3) ÉVÉNEMENTS COLIS — APPEND-ONLY ──────────────────────────────────────
-- Même patron que transit_file_events : l'historique d'un colis est une preuve
-- opposable au client, il ne se réécrit pas.
CREATE TABLE IF NOT EXISTS public.transit_parcel_events (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  parcel_id   uuid NOT NULL REFERENCES public.transit_parcels(id) ON DELETE CASCADE,
  event_type  text NOT NULL CHECK (event_type IN ('created', 'status_change', 'payment')),
  from_status text,
  to_status   text,
  amount      numeric,
  currency    text,
  note        text,
  actor_id    uuid NOT NULL REFERENCES public.profiles(id),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_transit_parcel_events_parcel
  ON public.transit_parcel_events (parcel_id, created_at DESC);

CREATE OR REPLACE RULE transit_parcel_events_no_update AS
  ON UPDATE TO public.transit_parcel_events DO INSTEAD NOTHING;
CREATE OR REPLACE RULE transit_parcel_events_no_delete AS
  ON DELETE TO public.transit_parcel_events DO INSTEAD NOTHING;

-- ── 4) RLS ─────────────────────────────────────────────────────────────────
ALTER TABLE public.transit_partners       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.transit_parcels        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.transit_parcel_events  ENABLE ROW LEVEL SECURITY;

-- Chaque partie ne voit QUE ses partenariats (owner ou partenaire).
DROP POLICY IF EXISTS transit_partners_read ON public.transit_partners;
CREATE POLICY transit_partners_read ON public.transit_partners FOR SELECT TO authenticated
  USING (owner_transitaire_id = (SELECT auth.uid()) OR partner_transitaire_id = (SELECT auth.uid()));

-- Écritures : uniquement par les RPC (SECURITY DEFINER), qui portent les règles
-- d'invitation/acceptation/révocation. Aucune policy d'écriture directe.

-- Colis : OWNER du dossier seulement (la vague B ouvrira aux partenaires actifs).
DROP POLICY IF EXISTS transit_parcels_owner ON public.transit_parcels;
CREATE POLICY transit_parcels_owner ON public.transit_parcels FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.transit_files f
                 WHERE f.id = file_id AND f.transitaire_id = (SELECT auth.uid())))
  WITH CHECK (EXISTS (SELECT 1 FROM public.transit_files f
                 WHERE f.id = file_id AND f.transitaire_id = (SELECT auth.uid())));

DROP POLICY IF EXISTS transit_parcel_events_read ON public.transit_parcel_events;
CREATE POLICY transit_parcel_events_read ON public.transit_parcel_events FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.transit_parcels p
                 JOIN public.transit_files f ON f.id = p.file_id
                 WHERE p.id = parcel_id AND f.transitaire_id = (SELECT auth.uid())));
-- Pas de policy INSERT : seules les RPC écrivent l'historique.

-- ── 5) RPC — INVITATION ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.transit_partner_invite(
  p_email text, p_role text DEFAULT 'agent_destination'
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); v_partner uuid; v_code text; v_id uuid;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'non authentifié'); END IF;
  IF p_role NOT IN ('agent_destination', 'agent_origine') THEN
    RETURN jsonb_build_object('success', false, 'error', 'rôle inconnu');
  END IF;

  -- Le partenaire peut ne pas encore exister : l'invitation reste valable par code.
  SELECT id INTO v_partner FROM public.profiles WHERE lower(email) = lower(btrim(p_email)) LIMIT 1;
  IF v_partner = v_uid THEN
    RETURN jsonb_build_object('success', false, 'error', 'auto-invitation impossible', 'error_code', 'SELF_INVITE');
  END IF;

  -- Idempotent : ré-inviter quelqu'un déjà lié renvoie le partenariat existant
  -- au lieu de violer l'index unique avec une erreur incompréhensible.
  IF v_partner IS NOT NULL THEN
    SELECT id, invite_code INTO v_id, v_code FROM public.transit_partners
    WHERE owner_transitaire_id = v_uid AND partner_transitaire_id = v_partner
      AND status IN ('invited', 'active');
    IF FOUND THEN
      RETURN jsonb_build_object('success', true, 'skipped', true, 'partnership_id', v_id, 'invite_code', v_code);
    END IF;
  END IF;

  v_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
  INSERT INTO public.transit_partners
    (owner_transitaire_id, partner_transitaire_id, partner_role, status, invite_code, invited_email, created_by)
  VALUES (v_uid, v_partner, p_role, 'invited', v_code, btrim(p_email), v_uid)
  RETURNING id INTO v_id;

  IF v_partner IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, title, message, type)
    VALUES (v_partner, 'Invitation de partenariat',
            'Un transitaire vous invite comme partenaire. Code : ' || v_code, 'info');
  END IF;

  RETURN jsonb_build_object('success', true, 'partnership_id', v_id, 'invite_code', v_code,
                            'partner_known', v_partner IS NOT NULL);
END; $$;

-- ── 6) RPC — ACCEPTATION (par le partenaire, jamais par l'owner) ───────────
CREATE OR REPLACE FUNCTION public.transit_partner_accept(p_invite_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); v_p record;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'non authentifié'); END IF;

  SELECT * INTO v_p FROM public.transit_partners
  WHERE invite_code = upper(btrim(p_invite_code)) FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'code inconnu', 'error_code', 'UNKNOWN_CODE'); END IF;
  IF v_p.status = 'revoked' THEN
    RETURN jsonb_build_object('success', false, 'error', 'invitation révoquée', 'error_code', 'REVOKED');
  END IF;
  IF v_p.owner_transitaire_id = v_uid THEN
    RETURN jsonb_build_object('success', false, 'error', 'auto-acceptation impossible', 'error_code', 'SELF_ACCEPT');
  END IF;
  -- Une invitation nominative ne peut pas être détournée par un autre compte.
  IF v_p.partner_transitaire_id IS NOT NULL AND v_p.partner_transitaire_id <> v_uid THEN
    RETURN jsonb_build_object('success', false, 'error', 'invitation destinée à un autre compte', 'error_code', 'NOT_YOURS');
  END IF;
  IF v_p.status = 'active' THEN
    RETURN jsonb_build_object('success', true, 'skipped', true, 'partnership_id', v_p.id);
  END IF;

  UPDATE public.transit_partners
  SET partner_transitaire_id = v_uid, status = 'active', accepted_at = now(), updated_at = now()
  WHERE id = v_p.id;

  INSERT INTO public.notifications (user_id, title, message, type)
  VALUES (v_p.owner_transitaire_id, 'Partenariat accepté',
          'Votre partenaire a accepté l''invitation.', 'success');

  RETURN jsonb_build_object('success', true, 'partnership_id', v_p.id, 'status', 'active');
END; $$;

-- ── 7) RPC — RÉVOCATION (par l'owner, effet immédiat) ──────────────────────
CREATE OR REPLACE FUNCTION public.transit_partner_revoke(p_partnership_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); v_p record;
BEGIN
  SELECT * INTO v_p FROM public.transit_partners WHERE id = p_partnership_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'partenariat introuvable'); END IF;
  -- Les DEUX parties peuvent rompre : subir un partenariat serait une prise d'otage.
  IF v_uid NOT IN (v_p.owner_transitaire_id, COALESCE(v_p.partner_transitaire_id, v_uid)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'forbidden', 'error_code', 'FORBIDDEN');
  END IF;
  IF v_p.owner_transitaire_id <> v_uid AND v_p.partner_transitaire_id <> v_uid THEN
    RETURN jsonb_build_object('success', false, 'error', 'forbidden', 'error_code', 'FORBIDDEN');
  END IF;
  IF v_p.status = 'revoked' THEN
    RETURN jsonb_build_object('success', true, 'skipped', true);
  END IF;

  UPDATE public.transit_partners
  SET status = 'revoked', revoked_at = now(), updated_at = now()
  WHERE id = p_partnership_id;

  INSERT INTO public.notifications (user_id, title, message, type)
  SELECT u, 'Partenariat révoqué', 'Le partenariat a pris fin. Les accès associés sont retirés.', 'warning'
  FROM unnest(ARRAY[v_p.owner_transitaire_id, v_p.partner_transitaire_id]) AS u
  WHERE u IS NOT NULL AND u <> v_uid;

  RETURN jsonb_build_object('success', true, 'partnership_id', p_partnership_id, 'status', 'revoked');
END; $$;

-- ── 8) RPC — CRÉATION DE COLIS (code scannable) ────────────────────────────
CREATE OR REPLACE FUNCTION public.transit_parcel_create(
  p_file_id uuid, p_description text DEFAULT NULL,
  p_weight_kg numeric DEFAULT NULL, p_volume_cbm numeric DEFAULT NULL,
  p_amount_due numeric DEFAULT 0, p_currency text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); v_owner uuid; v_code text; v_id uuid; v_cur text;
BEGIN
  SELECT transitaire_id INTO v_owner FROM public.transit_files WHERE id = p_file_id;
  IF v_owner IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'dossier introuvable'); END IF;
  IF v_owner <> v_uid THEN RETURN jsonb_build_object('success', false, 'error', 'forbidden', 'error_code', 'FORBIDDEN'); END IF;

  -- Devise : celle passée, sinon celle du pays de l'opérateur (verrou existant).
  v_cur := COALESCE(NULLIF(btrim(p_currency), ''),
                    public.resolve_default_currency((SELECT UPPER(COALESCE(country_code, country)) FROM public.profiles WHERE id = v_uid)),
                    'GNF');

  v_code := 'CL' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
  INSERT INTO public.transit_parcels
    (file_id, parcel_code, description, weight_kg, volume_cbm, amount_due, amount_currency, created_by)
  VALUES (p_file_id, v_code, p_description, p_weight_kg, p_volume_cbm, COALESCE(p_amount_due, 0), v_cur, v_uid)
  RETURNING id INTO v_id;

  INSERT INTO public.transit_parcel_events (parcel_id, event_type, to_status, actor_id)
  VALUES (v_id, 'created', 'recu_origine', v_uid);

  RETURN jsonb_build_object('success', true, 'parcel_id', v_id, 'parcel_code', v_code, 'currency', v_cur);
END; $$;

-- ── 9) RPC — TRANSITION DE STATUT ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.transit_parcel_set_status(
  p_parcel_id uuid, p_status text, p_note text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); v_p record; v_owner uuid;
BEGIN
  IF p_status NOT IN ('recu_origine', 'embarque', 'arrive_destination', 'livre') THEN
    RETURN jsonb_build_object('success', false, 'error', 'statut inconnu');
  END IF;

  SELECT p.*, f.transitaire_id AS owner_id INTO v_p
  FROM public.transit_parcels p JOIN public.transit_files f ON f.id = p.file_id
  WHERE p.id = p_parcel_id FOR UPDATE OF p;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'colis introuvable'); END IF;
  v_owner := v_p.owner_id;
  IF v_owner <> v_uid THEN RETURN jsonb_build_object('success', false, 'error', 'forbidden', 'error_code', 'FORBIDDEN'); END IF;
  IF v_p.status = p_status THEN
    RETURN jsonb_build_object('success', true, 'skipped', true, 'status', p_status);
  END IF;

  UPDATE public.transit_parcels SET status = p_status, updated_at = now() WHERE id = p_parcel_id;
  INSERT INTO public.transit_parcel_events (parcel_id, event_type, from_status, to_status, note, actor_id)
  VALUES (p_parcel_id, 'status_change', v_p.status, p_status, p_note, v_uid);

  RETURN jsonb_build_object('success', true, 'parcel_id', p_parcel_id, 'status', p_status);
END; $$;

-- ── 10) RPC — REGISTRE D'ENCAISSEMENT (aucun wallet touché) ────────────────
CREATE OR REPLACE FUNCTION public.transit_parcel_record_payment(
  p_parcel_id uuid, p_amount numeric, p_note text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); v_p record; v_total numeric; v_statut text;
BEGIN
  IF COALESCE(p_amount, 0) <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'montant invalide');
  END IF;

  SELECT p.*, f.transitaire_id AS owner_id INTO v_p
  FROM public.transit_parcels p JOIN public.transit_files f ON f.id = p.file_id
  WHERE p.id = p_parcel_id FOR UPDATE OF p;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'colis introuvable'); END IF;
  IF v_p.owner_id <> v_uid THEN RETURN jsonb_build_object('success', false, 'error', 'forbidden', 'error_code', 'FORBIDDEN'); END IF;

  v_total := ROUND(COALESCE(v_p.amount_paid, 0) + p_amount, public._ccy_decimals(v_p.amount_currency));
  -- Fail-closed : on n'encaisse pas plus que dû. Un trop-perçu silencieux
  -- fausserait la comptabilité et le compteur « payés » du réseau.
  IF v_p.amount_due > 0 AND v_total > v_p.amount_due THEN
    RETURN jsonb_build_object('success', false, 'error', 'montant supérieur au dû', 'error_code', 'OVER_PAYMENT',
                              'du', v_p.amount_due, 'deja_paye', v_p.amount_paid);
  END IF;

  v_statut := CASE WHEN v_p.amount_due > 0 AND v_total >= v_p.amount_due THEN 'paye'
                   WHEN v_total > 0 THEN 'partiel' ELSE 'non_paye' END;

  UPDATE public.transit_parcels
  SET amount_paid = v_total, payment_status = v_statut,
      collected_by = v_uid, collected_at = now(), updated_at = now()
  WHERE id = p_parcel_id;

  INSERT INTO public.transit_parcel_events (parcel_id, event_type, amount, currency, note, actor_id)
  VALUES (p_parcel_id, 'payment', p_amount, v_p.amount_currency, p_note, v_uid);

  RETURN jsonb_build_object('success', true, 'parcel_id', p_parcel_id, 'payment_status', v_statut,
                            'total_paye', v_total, 'currency', v_p.amount_currency);
END; $$;

-- ── 11) GRANTS ─────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.transit_partner_invite(text, text)            FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.transit_partner_accept(text)                  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.transit_partner_revoke(uuid)                  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.transit_parcel_create(uuid, text, numeric, numeric, numeric, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.transit_parcel_set_status(uuid, text, text)   FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.transit_parcel_record_payment(uuid, numeric, text) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.transit_partner_invite(text, text)            TO authenticated;
GRANT EXECUTE ON FUNCTION public.transit_partner_accept(text)                  TO authenticated;
GRANT EXECUTE ON FUNCTION public.transit_partner_revoke(uuid)                  TO authenticated;
GRANT EXECUTE ON FUNCTION public.transit_parcel_create(uuid, text, numeric, numeric, numeric, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transit_parcel_set_status(uuid, text, text)   TO authenticated;
GRANT EXECUTE ON FUNCTION public.transit_parcel_record_payment(uuid, numeric, text) TO authenticated;

SELECT 'Réseau transitaire vague A : partenariats + colis + événements append-only.' AS status;
