-- ═══════════════════════════════════════════════════════════════════════════════
-- PRESTATIONS — avancement du travail (le prestataire pilote, le client suit) + colonne vidéo
-- ═══════════════════════════════════════════════════════════════════════════════
-- « Terminé » ≠ libération : seul le CLIENT (ou l'auto-7j) libère le séquestre (release_quote_atomic).
-- On NE touche PAS pay_quote_atomic/release_quote_atomic : awaiting/validated sont DÉRIVÉS côté UI
-- (paid→awaiting, escrow released/completed→validated). Bloc 0 ne verrouille PAS work_status.

ALTER TABLE public.service_quotes
  ADD COLUMN IF NOT EXISTS work_status         text,          -- NULL/awaiting → in_progress → delivered (→ validated dérivé)
  ADD COLUMN IF NOT EXISTS work_started_at     timestamptz,
  ADD COLUMN IF NOT EXISTS expected_delivery_at timestamptz,
  ADD COLUMN IF NOT EXISTS delivered_at        timestamptz;

ALTER TABLE public.service_offerings ADD COLUMN IF NOT EXISTS video_url text;  -- vidéo marketing (plan premium)

-- ── Le prestataire DÉMARRE le travail (+ date de fin prévue) ──────────────────
CREATE OR REPLACE FUNCTION public.start_service_work(p_quote_id uuid, p_expected timestamptz DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE q public.service_quotes%ROWTYPE;
BEGIN
  SELECT * INTO q FROM public.service_quotes WHERE id = p_quote_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'QUOTE_NOT_FOUND'; END IF;
  IF NOT public.check_service_owner(q.professional_service_id) THEN RAISE EXCEPTION 'NOT_OWNER'; END IF;
  IF q.status <> 'paid' THEN RAISE EXCEPTION 'NOT_PAID'; END IF;   -- avancement seulement après paiement
  UPDATE public.service_quotes
    SET work_status = 'in_progress', work_started_at = now(),
        expected_delivery_at = COALESCE(p_expected, expected_delivery_at)
    WHERE id = p_quote_id;
  IF q.client_user_id IS NOT NULL THEN
    INSERT INTO public.notifications(user_id, title, message, type, category, link, metadata)
    VALUES (q.client_user_id, 'Prestation démarrée',
      q.title || CASE WHEN p_expected IS NOT NULL THEN ' — livraison prévue le ' || to_char(p_expected,'DD/MM/YYYY') ELSE '' END,
      'service_quote_started', 'quote', '/devis/' || p_quote_id::text,
      jsonb_build_object('quote_id', p_quote_id, 'link', '/devis/' || p_quote_id::text));
  END IF;
  RETURN jsonb_build_object('success', true, 'work_status', 'in_progress');
END; $$;

-- ── Le prestataire marque TERMINÉ (démarre le compteur 7j ; NE libère PAS) ─────
CREATE OR REPLACE FUNCTION public.mark_service_delivered(p_quote_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE q public.service_quotes%ROWTYPE;
BEGIN
  SELECT * INTO q FROM public.service_quotes WHERE id = p_quote_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'QUOTE_NOT_FOUND'; END IF;
  IF NOT public.check_service_owner(q.professional_service_id) THEN RAISE EXCEPTION 'NOT_OWNER'; END IF;
  IF q.status <> 'paid' THEN RAISE EXCEPTION 'NOT_PAID'; END IF;
  UPDATE public.service_quotes SET work_status = 'delivered', delivered_at = now() WHERE id = p_quote_id;
  IF q.client_user_id IS NOT NULL THEN
    INSERT INTO public.notifications(user_id, title, message, type, category, link, metadata)
    VALUES (q.client_user_id, 'Prestation terminée',
      q.title || ' — merci de valider pour libérer le paiement.',
      'service_quote_delivered', 'quote', '/devis/' || p_quote_id::text,
      jsonb_build_object('quote_id', p_quote_id, 'link', '/devis/' || p_quote_id::text));
  END IF;
  RETURN jsonb_build_object('success', true, 'work_status', 'delivered');
END; $$;

REVOKE ALL ON FUNCTION public.start_service_work(uuid,timestamptz)   FROM public, anon;
REVOKE ALL ON FUNCTION public.mark_service_delivered(uuid)           FROM public, anon;
GRANT EXECUTE ON FUNCTION public.start_service_work(uuid,timestamptz) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.mark_service_delivered(uuid)         TO authenticated, service_role;
