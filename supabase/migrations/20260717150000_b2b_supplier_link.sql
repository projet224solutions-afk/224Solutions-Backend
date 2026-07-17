-- ============================================================================
-- 🤝 APPROVISIONNEMENT 224 — Bloc 1 : LIAISON FOURNISSEUR (consentement)
-- ----------------------------------------------------------------------------
-- Un fournisseur du carnet (`vendor_suppliers`) peut être de deux sortes :
--   'externe' (défaut, hors app — flux manuel actuel inchangé)
--   'lie'     (c'est un vendeur 224Solutions, lié PAR CONSENTEMENT)
-- La liaison : l'acheteur envoie une demande → le fournisseur ACCEPTE/refuse
-- depuis son espace. Tout passe par des RPC atomiques service_role (le backend
-- Node notifie les deux côtés). Zéro régression : aucun défaut modifié.
-- Voir docs/APPROVISIONNEMENT_224.md (repo frontend).
-- ============================================================================

-- 1) ── vendor_suppliers : type + liaison ────────────────────────────────────
ALTER TABLE public.vendor_suppliers ADD COLUMN IF NOT EXISTS supplier_kind text NOT NULL DEFAULT 'externe';
ALTER TABLE public.vendor_suppliers ADD COLUMN IF NOT EXISTS linked_vendor_id uuid REFERENCES public.vendors(id) ON DELETE SET NULL;
ALTER TABLE public.vendor_suppliers ADD COLUMN IF NOT EXISTS link_status text NOT NULL DEFAULT 'none';

DO $$ BEGIN
  ALTER TABLE public.vendor_suppliers ADD CONSTRAINT vendor_suppliers_kind_chk
    CHECK (supplier_kind IN ('externe','lie'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE public.vendor_suppliers ADD CONSTRAINT vendor_suppliers_link_status_chk
    CHECK (link_status IN ('none','invited','pending','linked'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- Cohérence : 'lie' ⇔ un vendeur lié ; jamais lié à soi-même.
DO $$ BEGIN
  ALTER TABLE public.vendor_suppliers ADD CONSTRAINT vendor_suppliers_link_coherence_chk
    CHECK (
      (supplier_kind = 'lie' AND linked_vendor_id IS NOT NULL AND link_status = 'linked')
      OR (supplier_kind = 'externe' AND (link_status <> 'linked'))
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE public.vendor_suppliers ADD CONSTRAINT vendor_suppliers_no_self_link_chk
    CHECK (linked_vendor_id IS NULL OR linked_vendor_id <> vendor_id);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Un même vendeur lié ne peut apparaître qu'une fois dans le carnet d'un acheteur.
CREATE UNIQUE INDEX IF NOT EXISTS ux_vendor_suppliers_linked
  ON public.vendor_suppliers (vendor_id, linked_vendor_id)
  WHERE linked_vendor_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_vendor_suppliers_linked_vendor
  ON public.vendor_suppliers (linked_vendor_id) WHERE linked_vendor_id IS NOT NULL;

-- 2) ── Demandes de liaison (consentement) ───────────────────────────────────
CREATE TABLE IF NOT EXISTS public.supplier_link_requests (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  supplier_row_id     uuid NOT NULL REFERENCES public.vendor_suppliers(id) ON DELETE CASCADE,
  requester_vendor_id uuid NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  target_vendor_id    uuid NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  status              text NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending','accepted','rejected','cancelled')),
  message             text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  responded_at        timestamptz,
  CHECK (requester_vendor_id <> target_vendor_id)
);
-- Une seule demande EN ATTENTE par fiche fournisseur.
CREATE UNIQUE INDEX IF NOT EXISTS ux_supplier_link_requests_pending
  ON public.supplier_link_requests (supplier_row_id) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_supplier_link_requests_target
  ON public.supplier_link_requests (target_vendor_id, status);
CREATE INDEX IF NOT EXISTS idx_supplier_link_requests_requester
  ON public.supplier_link_requests (requester_vendor_id, status);

ALTER TABLE public.supplier_link_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS supplier_link_requests_parties ON public.supplier_link_requests;
CREATE POLICY supplier_link_requests_parties ON public.supplier_link_requests
  FOR SELECT TO authenticated
  USING (
    requester_vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
    OR target_vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
    OR public.is_admin_or_pdg()
  );
-- Écritures = backend (service_role) uniquement, via les RPC ci-dessous.

-- 3) ── RPC : envoyer une demande de liaison (atomique) ──────────────────────
CREATE OR REPLACE FUNCTION public.request_supplier_link(
  p_supplier_row_id uuid, p_requester_vendor_id uuid, p_target_vendor_id uuid,
  p_message text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_supplier record; v_target record; v_requester record; v_request_id uuid;
BEGIN
  IF p_supplier_row_id IS NULL OR p_requester_vendor_id IS NULL OR p_target_vendor_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'MISSING_PARAMS');
  END IF;
  IF p_requester_vendor_id = p_target_vendor_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'SELF_LINK_FORBIDDEN');
  END IF;

  SELECT * INTO v_supplier FROM public.vendor_suppliers
  WHERE id = p_supplier_row_id AND vendor_id = p_requester_vendor_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'SUPPLIER_NOT_FOUND'); END IF;
  IF v_supplier.link_status = 'linked' THEN
    RETURN jsonb_build_object('success', false, 'error', 'ALREADY_LINKED');
  END IF;
  IF v_supplier.link_status = 'pending' THEN
    RETURN jsonb_build_object('success', false, 'error', 'REQUEST_ALREADY_PENDING');
  END IF;

  SELECT v.id, v.user_id, v.business_name INTO v_target
  FROM public.vendors v WHERE v.id = p_target_vendor_id;
  IF NOT FOUND OR v_target.user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'TARGET_VENDOR_NOT_FOUND');
  END IF;
  -- Ce vendeur est-il déjà lié via une AUTRE fiche du même acheteur ?
  IF EXISTS (
    SELECT 1 FROM public.vendor_suppliers
    WHERE vendor_id = p_requester_vendor_id AND linked_vendor_id = p_target_vendor_id
      AND id <> p_supplier_row_id
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'VENDOR_ALREADY_LINKED_ELSEWHERE');
  END IF;

  SELECT v.id, v.user_id, v.business_name INTO v_requester
  FROM public.vendors v WHERE v.id = p_requester_vendor_id;

  INSERT INTO public.supplier_link_requests
    (supplier_row_id, requester_vendor_id, target_vendor_id, status, message)
  VALUES (p_supplier_row_id, p_requester_vendor_id, p_target_vendor_id, 'pending', p_message)
  RETURNING id INTO v_request_id;

  UPDATE public.vendor_suppliers
  SET link_status = 'pending', updated_at = now()
  WHERE id = p_supplier_row_id;

  RETURN jsonb_build_object('success', true, 'request_id', v_request_id,
    'target_user_id', v_target.user_id, 'target_business_name', v_target.business_name,
    'requester_user_id', v_requester.user_id, 'requester_business_name', v_requester.business_name,
    'supplier_name', v_supplier.name);
EXCEPTION WHEN unique_violation THEN
  RETURN jsonb_build_object('success', false, 'error', 'REQUEST_ALREADY_PENDING');
END;
$$;
REVOKE ALL ON FUNCTION public.request_supplier_link(uuid, uuid, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.request_supplier_link(uuid, uuid, uuid, text) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.request_supplier_link(uuid, uuid, uuid, text) TO service_role;

-- 4) ── RPC : répondre à une demande (accepter / refuser, atomique) ──────────
CREATE OR REPLACE FUNCTION public.respond_supplier_link(
  p_request_id uuid, p_responder_vendor_id uuid, p_accept boolean
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_req record; v_requester record; v_responder record; v_supplier_name text;
BEGIN
  IF p_request_id IS NULL OR p_responder_vendor_id IS NULL OR p_accept IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'MISSING_PARAMS');
  END IF;

  SELECT * INTO v_req FROM public.supplier_link_requests
  WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'REQUEST_NOT_FOUND'); END IF;
  IF v_req.target_vendor_id <> p_responder_vendor_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_YOUR_REQUEST');
  END IF;
  IF v_req.status <> 'pending' THEN
    -- Idempotent : re-réponse identique = succès silencieux, sinon conflit.
    RETURN jsonb_build_object('success', true, 'already_responded', true, 'status', v_req.status);
  END IF;

  UPDATE public.supplier_link_requests
  SET status = CASE WHEN p_accept THEN 'accepted' ELSE 'rejected' END, responded_at = now()
  WHERE id = p_request_id;

  IF p_accept THEN
    UPDATE public.vendor_suppliers
    SET supplier_kind = 'lie', linked_vendor_id = v_req.target_vendor_id,
        link_status = 'linked', updated_at = now()
    WHERE id = v_req.supplier_row_id
    RETURNING name INTO v_supplier_name;
  ELSE
    UPDATE public.vendor_suppliers
    SET link_status = 'none', updated_at = now()
    WHERE id = v_req.supplier_row_id
    RETURNING name INTO v_supplier_name;
  END IF;
  IF v_supplier_name IS NULL THEN
    RAISE EXCEPTION 'SUPPLIER_ROW_GONE';
  END IF;

  SELECT v.user_id, v.business_name INTO v_requester FROM public.vendors v WHERE v.id = v_req.requester_vendor_id;
  SELECT v.user_id, v.business_name INTO v_responder FROM public.vendors v WHERE v.id = v_req.target_vendor_id;

  RETURN jsonb_build_object('success', true, 'accepted', p_accept,
    'supplier_row_id', v_req.supplier_row_id, 'supplier_name', v_supplier_name,
    'requester_vendor_id', v_req.requester_vendor_id,
    'requester_user_id', v_requester.user_id, 'requester_business_name', v_requester.business_name,
    'responder_user_id', v_responder.user_id, 'responder_business_name', v_responder.business_name);
END;
$$;
REVOKE ALL ON FUNCTION public.respond_supplier_link(uuid, uuid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.respond_supplier_link(uuid, uuid, boolean) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.respond_supplier_link(uuid, uuid, boolean) TO service_role;

SELECT 'Bloc 1 liaison fournisseur : vendor_suppliers (kind/lien) + supplier_link_requests + RPC request/respond (service_role).' AS status;
