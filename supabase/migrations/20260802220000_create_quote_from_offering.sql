-- ═══════════════════════════════════════════════════════════════════════════════
-- PRESTATIONS IT — Bloc 3 (serveur) : le CLIENT commande une prestation → crée un devis pré-rempli
-- ═══════════════════════════════════════════════════════════════════════════════
-- Livré en FICHIER — appliqué en prod via l'API Management.
--
-- La RLS `quotes_owner` de service_quotes est FOR ALL réservée à l'OWNER → un client ne peut PAS INSERT un
-- devis directement. Cette RPC SECURITY DEFINER crée le devis À PARTIR d'une prestation active, au nom du
-- client (client_user_id = auth.uid()), status='sent'. AUCUN mouvement d'argent ici : le paiement/validation
-- passent ensuite par le circuit EXISTANT (pay_quote_atomic / release_quote_atomic). Le montant vient du
-- SERVEUR (base_price de l'offering) — le client ne fournit aucun montant.

CREATE OR REPLACE FUNCTION public.create_quote_from_offering(p_offering_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_client uuid := auth.uid();
  v_off    record;
  v_qid    uuid;
BEGIN
  IF v_client IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_AUTHENTICATED');
  END IF;

  -- Prestation ACTIVE + son propriétaire (montant = base_price serveur, jamais fourni par le client).
  SELECT o.id, o.professional_service_id, o.title, o.description, o.base_price, o.escrow, ps.user_id AS owner_id
  INTO v_off
  FROM public.service_offerings o
  JOIN public.professional_services ps ON ps.id = o.professional_service_id
  WHERE o.id = p_offering_id AND o.is_active = true;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'OFFERING_NOT_FOUND');
  END IF;
  IF v_off.owner_id IS NOT DISTINCT FROM v_client THEN
    RETURN jsonb_build_object('success', false, 'error', 'OWN_OFFERING');  -- on ne commande pas sa propre prestation
  END IF;
  IF COALESCE(v_off.base_price, 0) <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'BAD_PRICE');
  END IF;

  INSERT INTO public.service_quotes (
    professional_service_id, client_user_id, title, description,
    line_items, total_amount, escrow, escrow_status, status)
  VALUES (
    v_off.professional_service_id, v_client, v_off.title, v_off.description,
    jsonb_build_array(jsonb_build_object('label', v_off.title, 'qty', 1, 'unit_price', v_off.base_price)),
    v_off.base_price, COALESCE(v_off.escrow, true), 'none', 'sent')
  RETURNING id INTO v_qid;

  RETURN jsonb_build_object('success', true, 'quote_id', v_qid, 'total_amount', v_off.base_price);
END;
$$;

REVOKE ALL ON FUNCTION public.create_quote_from_offering(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_quote_from_offering(uuid) TO authenticated, service_role;

-- Vérif : un client (≠ owner) appelle create_quote_from_offering(<offering actif>) → un service_quotes 'sent'
-- avec total_amount = base_price. Puis pay_quote_atomic / release_quote_atomic (circuit existant) inchangés.
