-- ============================================================================
-- SOCLE DEVIS & PORTFOLIO (PHASE 3) — réutilisable par les services « sur projet » :
-- Maison/Déco, Photo/Vidéo, Freelance, Réparation, Informatique (signatures Houzz /
-- Fiverr / YourMechanic). Le prestataire envoie un DEVIS ; le client paie (direct ou
-- ESCROW selon le service) ; pour l'escrow le client VALIDE pour libérer les fonds.
-- + Galerie de réalisations (portfolio public). Commission = plan du prestataire,
-- repli sur service_types.commission_rate. RPC argent REVOKE FROM PUBLIC. Rejouable.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.service_quotes (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id uuid NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  client_user_id          uuid REFERENCES auth.users(id),
  client_name             text,
  client_phone            text,
  title                   text NOT NULL,
  description             text,
  line_items              jsonb NOT NULL DEFAULT '[]',   -- [{label, qty, unit_price}]
  total_amount            numeric(12,2) NOT NULL DEFAULT 0,
  escrow                  boolean NOT NULL DEFAULT false,  -- true = fonds séquestrés jusqu'à validation client
  escrow_status           text NOT NULL DEFAULT 'none' CHECK (escrow_status IN ('none','held','released')),
  status                  text NOT NULL DEFAULT 'sent' CHECK (status IN ('draft','sent','paid','completed','cancelled')),
  created_at              timestamptz DEFAULT now(),
  paid_at                 timestamptz,
  completed_at            timestamptz
);
CREATE INDEX IF NOT EXISTS idx_service_quotes_service ON public.service_quotes (professional_service_id, status);
CREATE INDEX IF NOT EXISTS idx_service_quotes_client ON public.service_quotes (client_user_id);

CREATE TABLE IF NOT EXISTS public.service_portfolio (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id uuid NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  title                   text NOT NULL,
  description             text,
  image_url               text NOT NULL,
  category                text,
  created_at              timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_service_portfolio_service ON public.service_portfolio (professional_service_id);

-- ── RLS ─────────────────────────────────────────────────────────────────────
ALTER TABLE public.service_quotes    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.service_portfolio ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS quotes_owner ON public.service_quotes;
CREATE POLICY quotes_owner ON public.service_quotes
  FOR ALL USING (public.check_service_owner(professional_service_id))
  WITH CHECK (public.check_service_owner(professional_service_id));
DROP POLICY IF EXISTS quotes_client_read ON public.service_quotes;
CREATE POLICY quotes_client_read ON public.service_quotes
  FOR SELECT TO authenticated USING (client_user_id = auth.uid());

DROP POLICY IF EXISTS portfolio_owner ON public.service_portfolio;
CREATE POLICY portfolio_owner ON public.service_portfolio
  FOR ALL USING (public.check_service_owner(professional_service_id))
  WITH CHECK (public.check_service_owner(professional_service_id));
DROP POLICY IF EXISTS portfolio_public_read ON public.service_portfolio;
CREATE POLICY portfolio_public_read ON public.service_portfolio FOR SELECT USING (true);

-- ── RPC : lecture d'un devis partagé (lien) — pour la page publique de paiement ──
CREATE OR REPLACE FUNCTION public.get_shared_quote(p_quote_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE q public.service_quotes%ROWTYPE; v_biz text;
BEGIN
  SELECT * INTO q FROM public.service_quotes WHERE id = p_quote_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('found', false); END IF;
  SELECT business_name INTO v_biz FROM public.professional_services WHERE id = q.professional_service_id;
  RETURN jsonb_build_object('found', true, 'id', q.id, 'title', q.title, 'description', q.description,
    'line_items', q.line_items, 'total_amount', q.total_amount, 'escrow', q.escrow,
    'status', q.status, 'client_name', q.client_name, 'business_name', v_biz);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.get_shared_quote(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.get_shared_quote(uuid) TO anon, authenticated, service_role;

-- ── RPC : le client PAIE le devis (direct → prestataire net, ou ESCROW → séquestre) ──
CREATE OR REPLACE FUNCTION public.pay_quote_atomic(p_actor_user_id uuid, p_quote_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE q public.service_quotes%ROWTYPE; v_provider uuid; v_code text; v_def numeric; v_rate numeric; v_commission numeric; v_pdg uuid;
BEGIN
  SELECT * INTO q FROM public.service_quotes WHERE id = p_quote_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'QUOTE_NOT_FOUND'; END IF;
  IF q.status IN ('paid','completed') THEN RETURN jsonb_build_object('success', true, 'already', true); END IF;
  IF q.status = 'cancelled' THEN RAISE EXCEPTION 'QUOTE_CANCELLED'; END IF;
  IF COALESCE(q.total_amount,0) <= 0 THEN RAISE EXCEPTION 'BAD_AMOUNT'; END IF;

  SELECT ps.user_id, st.code, COALESCE(st.commission_rate, 10)
    INTO v_provider, v_code, v_def
  FROM public.professional_services ps JOIN public.service_types st ON st.id = ps.service_type_id
  WHERE ps.id = q.professional_service_id;
  IF v_provider = p_actor_user_id THEN RAISE EXCEPTION 'OWN_QUOTE'; END IF;

  PERFORM public.wallet_debit_internal(p_actor_user_id, q.total_amount, 'Paiement devis : ' || q.title, 'quote-pay-' || p_quote_id::text);

  IF q.escrow THEN
    -- Fonds séquestrés (libérés à la validation du client)
    UPDATE public.service_quotes SET status = 'paid', escrow_status = 'held', paid_at = now(),
      client_user_id = COALESCE(client_user_id, p_actor_user_id) WHERE id = p_quote_id;
    RETURN jsonb_build_object('success', true, 'escrow', true);
  ELSE
    v_rate := public.resolve_service_commission_rate(v_provider, v_code, v_def);
    v_commission := round(q.total_amount * v_rate / 100.0);
    SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;
    PERFORM public.credit_user_wallet_safe(v_provider, q.total_amount - v_commission, 'GNF', 'quote_payment', p_quote_id::text);
    IF v_pdg IS NOT NULL AND v_commission > 0 THEN
      PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, 'GNF', 'quote_commission', p_quote_id::text);
    END IF;
    UPDATE public.service_quotes SET status = 'paid', paid_at = now(),
      client_user_id = COALESCE(client_user_id, p_actor_user_id) WHERE id = p_quote_id;
    RETURN jsonb_build_object('success', true, 'escrow', false);
  END IF;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.pay_quote_atomic(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.pay_quote_atomic(uuid, uuid) TO service_role;

-- ── RPC : le client VALIDE (escrow) → libère les fonds au prestataire net commission ──
CREATE OR REPLACE FUNCTION public.release_quote_atomic(p_actor_user_id uuid, p_quote_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE q public.service_quotes%ROWTYPE; v_provider uuid; v_code text; v_def numeric; v_rate numeric; v_commission numeric; v_pdg uuid;
BEGIN
  SELECT * INTO q FROM public.service_quotes WHERE id = p_quote_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'QUOTE_NOT_FOUND'; END IF;
  IF q.client_user_id <> p_actor_user_id THEN RAISE EXCEPTION 'NOT_CLIENT'; END IF;
  IF q.escrow_status = 'released' THEN RETURN jsonb_build_object('success', true, 'already', true); END IF;
  IF NOT q.escrow OR q.escrow_status <> 'held' THEN RAISE EXCEPTION 'NOT_HELD'; END IF;

  SELECT ps.user_id, st.code, COALESCE(st.commission_rate, 10)
    INTO v_provider, v_code, v_def
  FROM public.professional_services ps JOIN public.service_types st ON st.id = ps.service_type_id
  WHERE ps.id = q.professional_service_id;

  v_rate := public.resolve_service_commission_rate(v_provider, v_code, v_def);
  v_commission := round(q.total_amount * v_rate / 100.0);
  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;
  PERFORM public.credit_user_wallet_safe(v_provider, q.total_amount - v_commission, 'GNF', 'quote_release', p_quote_id::text);
  IF v_pdg IS NOT NULL AND v_commission > 0 THEN
    PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, 'GNF', 'quote_commission', p_quote_id::text);
  END IF;
  UPDATE public.service_quotes SET escrow_status = 'released', status = 'completed', completed_at = now() WHERE id = p_quote_id;
  RETURN jsonb_build_object('success', true, 'released', q.total_amount - v_commission);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.release_quote_atomic(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.release_quote_atomic(uuid, uuid) TO service_role;

SELECT 'Socle Devis & Portfolio créé : service_quotes + service_portfolio + RPC paiement/escrow atomiques.' AS status;
