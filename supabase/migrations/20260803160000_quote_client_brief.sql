-- ═══════════════════════════════════════════════════════════════════════════════
-- SUR-DEVIS PRO — brief structuré du client (le prestataire sait quoi chiffrer)
-- ═══════════════════════════════════════════════════════════════════════════════
-- Avant : « Demander un devis » créait un devis VIDE → le prestataire ne peut pas chiffrer juste.
-- Après : le client décrit son besoin (description, délai, budget indicatif, pièces jointes) → stocké
-- sur le devis (client_brief jsonb + attachments jsonb). create_quote_from_offering accepte le brief.

ALTER TABLE public.service_quotes
  ADD COLUMN IF NOT EXISTS client_brief jsonb,
  ADD COLUMN IF NOT EXISTS attachments  jsonb NOT NULL DEFAULT '[]'::jsonb;

-- Recréation (ajout du paramètre p_brief) : DROP + CREATE (la signature change).
DROP FUNCTION IF EXISTS public.create_quote_from_offering(uuid);

CREATE OR REPLACE FUNCTION public.create_quote_from_offering(p_offering_id uuid, p_brief jsonb DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_client uuid := auth.uid();
  v_off    record;
  v_qid    uuid;
  v_status text;
  v_amount numeric;
  v_desc   text;
BEGIN
  IF v_client IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'NOT_AUTHENTICATED'); END IF;

  SELECT o.id, o.professional_service_id, o.title, o.description, o.base_price, o.escrow,
         COALESCE(o.price_type, 'fixed') AS price_type, ps.user_id AS owner_id
  INTO v_off
  FROM public.service_offerings o
  JOIN public.professional_services ps ON ps.id = o.professional_service_id
  WHERE o.id = p_offering_id AND o.is_active = true;

  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'OFFERING_NOT_FOUND'); END IF;
  IF v_off.owner_id IS NOT DISTINCT FROM v_client THEN RETURN jsonb_build_object('success', false, 'error', 'OWN_OFFERING'); END IF;

  -- Brief OBLIGATOIRE pour les prestations « sur devis » / « à partir de » (pas pour le prix fixe).
  IF v_off.price_type <> 'fixed'
     AND (p_brief IS NULL OR btrim(COALESCE(p_brief->>'description','')) = '') THEN
    RETURN jsonb_build_object('success', false, 'error', 'BRIEF_REQUIRED');
  END IF;

  IF v_off.price_type = 'fixed' THEN
    IF COALESCE(v_off.base_price, 0) <= 0 THEN RETURN jsonb_build_object('success', false, 'error', 'BAD_PRICE'); END IF;
    v_status := 'sent'; v_amount := v_off.base_price;
  ELSE
    v_status := 'draft'; v_amount := CASE WHEN v_off.price_type = 'from' THEN COALESCE(v_off.base_price, 0) ELSE 0 END;
  END IF;

  INSERT INTO public.service_quotes (
    professional_service_id, client_user_id, title, description, line_items, total_amount,
    escrow, escrow_status, status, client_brief, attachments)
  VALUES (
    v_off.professional_service_id, v_client, v_off.title, v_off.description,
    jsonb_build_array(jsonb_build_object('label', v_off.title, 'qty', 1, 'unit_price', v_amount)),
    v_amount, COALESCE(v_off.escrow, true), 'none', v_status,
    p_brief, COALESCE(p_brief->'attachments', '[]'::jsonb))
  RETURNING id INTO v_qid;

  -- Notifier le prestataire — CLIQUABLE vers le devis (voit le brief) + résumé du besoin.
  v_desc := left(COALESCE(p_brief->>'description', v_off.description, ''), 140);
  BEGIN
    INSERT INTO public.notifications (user_id, title, message, type, metadata)
    VALUES (
      v_off.owner_id,
      CASE WHEN v_status = 'draft' THEN 'Nouvelle demande de devis' ELSE 'Nouvelle commande de prestation' END,
      v_off.title || CASE WHEN v_desc <> '' THEN ' — ' || v_desc ELSE '' END,
      'service_quote_order',
      jsonb_build_object('quote_id', v_qid, 'offering_id', v_off.id, 'price_type', v_off.price_type, 'link', '/devis/' || v_qid::text));
  EXCEPTION WHEN others THEN NULL;
  END;

  RETURN jsonb_build_object('success', true, 'quote_id', v_qid, 'total_amount', v_amount,
                            'status', v_status, 'needs_pricing', v_status = 'draft');
END;
$function$;

REVOKE ALL ON FUNCTION public.create_quote_from_offering(uuid, jsonb) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.create_quote_from_offering(uuid, jsonb) TO authenticated, service_role;
