-- ============================================================================
-- SERVICES ARTISANS — Phase 1 : PARCOURS CLIENT (demande → devis multiples → choix)
-- ----------------------------------------------------------------------------
-- Un client publie une DEMANDE (métier + détails + photos + urgence). Les artisans du
-- métier la voient (via RPC backend) et déposent un DEVIS lié à la demande. Le client
-- compare (jusqu'à 3 côte à côte) et en accepte un → l'acceptation refuse les concurrents
-- et passe la demande en « assigned ». Tout-ou-rien, idempotent, REVOKE FROM PUBLIC.
-- Rejouable.
-- ============================================================================

-- ── 1) Table des demandes client ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.artisan_requests (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id         uuid NOT NULL REFERENCES auth.users(id),
  service_type      text NOT NULL CHECK (service_type IN ('vitrerie','menuiserie','plomberie','soudure')),
  title             text NOT NULL,
  description       text,
  photos            text[] DEFAULT '{}',
  address           text,
  city              text,
  latitude          double precision,
  longitude         double precision,
  urgency           text NOT NULL DEFAULT 'normal' CHECK (urgency IN ('normal','urgent','immediate')),
  preferred_date    timestamptz,
  status            text NOT NULL DEFAULT 'open' CHECK (status IN ('open','quoted','assigned','closed','cancelled')),
  accepted_quote_id uuid,
  quotes_count      integer NOT NULL DEFAULT 0,
  created_at        timestamptz DEFAULT now(),
  updated_at        timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_artisan_req_client  ON public.artisan_requests (client_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_artisan_req_open     ON public.artisan_requests (service_type, status, created_at DESC);

-- ── 2) Lien devis → demande ──────────────────────────────────────────────────
ALTER TABLE public.artisan_quotes ADD COLUMN IF NOT EXISTS request_id uuid REFERENCES public.artisan_requests(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_artisan_quotes_request ON public.artisan_quotes (request_id);

-- ── 3) RLS : le client voit/gère SES demandes ; le parcours artisan passe par les RPC ──
ALTER TABLE public.artisan_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS artisan_req_select_own ON public.artisan_requests;
CREATE POLICY artisan_req_select_own ON public.artisan_requests
  FOR SELECT TO authenticated USING (client_id = auth.uid() OR public.is_admin_or_pdg());

DROP POLICY IF EXISTS artisan_req_client_update ON public.artisan_requests;
CREATE POLICY artisan_req_client_update ON public.artisan_requests
  FOR UPDATE TO authenticated USING (client_id = auth.uid()) WITH CHECK (client_id = auth.uid());

-- ── 4) RPC : le client crée une demande (validée, server-side) ───────────────
CREATE OR REPLACE FUNCTION public.create_artisan_request(
  p_client_id uuid, p_service_type text, p_title text, p_description text,
  p_photos text[], p_address text, p_city text,
  p_latitude double precision, p_longitude double precision,
  p_urgency text, p_preferred_date timestamptz
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid;
BEGIN
  IF p_client_id IS NULL THEN RAISE EXCEPTION 'NO_CLIENT'; END IF;
  IF p_service_type NOT IN ('vitrerie','menuiserie','plomberie','soudure') THEN RAISE EXCEPTION 'BAD_SERVICE_TYPE'; END IF;
  IF COALESCE(btrim(p_title),'') = '' THEN RAISE EXCEPTION 'TITLE_REQUIRED'; END IF;

  INSERT INTO public.artisan_requests (client_id, service_type, title, description, photos, address, city, latitude, longitude, urgency, preferred_date)
  VALUES (p_client_id, p_service_type, btrim(p_title), p_description, COALESCE(p_photos,'{}'), p_address, p_city, p_latitude, p_longitude,
          COALESCE(NULLIF(p_urgency,''),'normal'), p_preferred_date)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('success', true, 'request_id', v_id);
END;
$$;

-- ── 5) RPC : liste des demandes ouvertes pour les métiers d'un artisan ───────
-- (Job board : renvoyé au backend qui le filtre selon les métiers réels de l'artisan.)
CREATE OR REPLACE FUNCTION public.list_open_artisan_requests(p_service_types text[], p_limit integer DEFAULT 50)
RETURNS SETOF public.artisan_requests
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT * FROM public.artisan_requests
  WHERE status IN ('open','quoted') AND service_type = ANY(p_service_types)
  ORDER BY CASE urgency WHEN 'immediate' THEN 0 WHEN 'urgent' THEN 1 ELSE 2 END, created_at DESC
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit,50), 200));
$$;

-- ── 6) RPC : un artisan dépose (ou met à jour) son devis pour une demande ────
-- Atomique : 1 devis par artisan/demande, demande verrouillée, statut contrôlé.
CREATE OR REPLACE FUNCTION public.submit_artisan_quote_for_request(
  p_request_id uuid, p_artisan_id uuid, p_items jsonb,
  p_total_ht numeric, p_tax_rate numeric, p_total_ttc numeric,
  p_photos text[], p_notes text, p_valid_until timestamptz
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.artisan_requests%ROWTYPE; v_quote uuid;
BEGIN
  SELECT * INTO r FROM public.artisan_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'REQUEST_NOT_FOUND'; END IF;
  IF r.status NOT IN ('open','quoted') THEN RAISE EXCEPTION 'REQUEST_CLOSED (%)', r.status; END IF;
  IF p_artisan_id IS NULL THEN RAISE EXCEPTION 'NO_ARTISAN'; END IF;
  IF p_artisan_id = r.client_id THEN RAISE EXCEPTION 'CANNOT_QUOTE_OWN_REQUEST'; END IF;

  -- 1 devis par artisan & par demande (re-soumission = mise à jour).
  SELECT id INTO v_quote FROM public.artisan_quotes
    WHERE request_id = p_request_id AND artisan_id = p_artisan_id LIMIT 1;

  IF v_quote IS NULL THEN
    INSERT INTO public.artisan_quotes (artisan_id, client_id, request_id, service_type, status, items, total_ht, tax_rate, total_ttc, photos, notes, valid_until)
    VALUES (p_artisan_id, r.client_id, p_request_id, r.service_type, 'sent', COALESCE(p_items,'[]'::jsonb), p_total_ht, COALESCE(p_tax_rate,18), p_total_ttc, COALESCE(p_photos,'{}'), p_notes, p_valid_until)
    RETURNING id INTO v_quote;
  ELSE
    UPDATE public.artisan_quotes
      SET items = COALESCE(p_items,'[]'::jsonb), total_ht = p_total_ht, tax_rate = COALESCE(p_tax_rate,18),
          total_ttc = p_total_ttc, photos = COALESCE(p_photos,'{}'), notes = p_notes, valid_until = p_valid_until,
          status = 'sent', updated_at = now()
      WHERE id = v_quote;
  END IF;

  UPDATE public.artisan_requests
    SET status = CASE WHEN status = 'open' THEN 'quoted' ELSE status END,
        quotes_count = (SELECT count(*) FROM public.artisan_quotes WHERE request_id = p_request_id),
        updated_at = now()
    WHERE id = p_request_id;

  RETURN jsonb_build_object('success', true, 'quote_id', v_quote);
END;
$$;

-- ── 7) Acceptation enrichie : refuse les devis concurrents + assigne la demande ──
CREATE OR REPLACE FUNCTION public.accept_artisan_quote_atomic(p_quote_id uuid, p_actor_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE q public.artisan_quotes%ROWTYPE; v_interv uuid;
BEGIN
  SELECT * INTO q FROM public.artisan_quotes WHERE id = p_quote_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'QUOTE_NOT_FOUND'; END IF;
  IF p_actor_user_id <> q.client_id THEN RAISE EXCEPTION 'NOT_CLIENT'; END IF;

  IF q.status = 'accepted' THEN
    SELECT id INTO v_interv FROM public.artisan_interventions WHERE quote_id = p_quote_id LIMIT 1;
    RETURN jsonb_build_object('success', true, 'already', true, 'intervention_id', v_interv);
  END IF;
  IF q.status NOT IN ('sent','viewed') THEN RAISE EXCEPTION 'QUOTE_NOT_ACCEPTABLE (%)', q.status; END IF;

  UPDATE public.artisan_quotes SET status = 'accepted', signed_at = now(), updated_at = now() WHERE id = p_quote_id;

  INSERT INTO public.artisan_interventions (artisan_id, client_id, quote_id, service_type, status)
  VALUES (q.artisan_id, q.client_id, q.id, q.service_type, 'scheduled')
  RETURNING id INTO v_interv;

  -- Lié à une demande : refuser les concurrents + assigner.
  IF q.request_id IS NOT NULL THEN
    UPDATE public.artisan_quotes
      SET status = 'refused', updated_at = now()
      WHERE request_id = q.request_id AND id <> q.id AND status IN ('sent','viewed','draft');
    UPDATE public.artisan_requests
      SET status = 'assigned', accepted_quote_id = q.id, updated_at = now()
      WHERE id = q.request_id;
  END IF;

  RETURN jsonb_build_object('success', true, 'intervention_id', v_interv, 'total_ttc', q.total_ttc);
END;
$$;

-- ── 8) Durcissement : REVOKE FROM PUBLIC, backend (service_role) uniquement ───
REVOKE EXECUTE ON FUNCTION public.create_artisan_request(uuid, text, text, text, text[], text, text, double precision, double precision, text, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.create_artisan_request(uuid, text, text, text, text[], text, text, double precision, double precision, text, timestamptz) TO service_role;
REVOKE EXECUTE ON FUNCTION public.list_open_artisan_requests(text[], integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.list_open_artisan_requests(text[], integer) TO service_role;
REVOKE EXECUTE ON FUNCTION public.submit_artisan_quote_for_request(uuid, uuid, jsonb, numeric, numeric, numeric, text[], text, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.submit_artisan_quote_for_request(uuid, uuid, jsonb, numeric, numeric, numeric, text[], text, timestamptz) TO service_role;
REVOKE EXECUTE ON FUNCTION public.accept_artisan_quote_atomic(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.accept_artisan_quote_atomic(uuid, uuid) TO service_role;

SELECT 'Parcours client artisan créé (artisan_requests + RPC create/list/submit/accept durcies).' AS status;
