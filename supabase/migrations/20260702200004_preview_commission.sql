-- ============================================================================
-- PREVIEW COMMISSION — le client voit le TOTAL (montant + commission) AVANT de payer
-- ----------------------------------------------------------------------------
-- Lecture seule (aucun mouvement d'argent). Reproduit EXACTEMENT le calcul de
-- commission de chaque RPC de paiement (même resolve_service_commission_rate,
-- même round) → garantit « affiché == débité ». Renvoie {amount, rate, commission,
-- total}. GRANT authenticated (le client interroge avant de payer ; rien de sensible).
--   • rent            : owner=properties.owner_id, taux 'location' (défaut 0), amount=loyer.
--   • restaurant      : owner=professional_services.user_id, taux 'restaurant' (défaut 15),
--                       amount = sous-total PLATS (hors livraison, non commissionnée).
--   • quote           : provider+code du devis, taux service (défaut st.commission_rate/10),
--                       amount = service_quotes.total_amount.
--   • artisan_deposit : amount = round(total_ttc × pct%), taux = service_types.commission_rate (défaut 5).
--   • artisan_balance : amount = total_ttc − amount_paid, même taux.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.preview_commission(
  p_flow        text,
  p_ref_id      uuid,
  p_amount      numeric DEFAULT NULL,
  p_deposit_pct numeric DEFAULT 30
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_owner uuid; v_provider uuid; v_code text; v_def numeric;
  v_rate numeric := 0; v_amount numeric := COALESCE(p_amount, 0); v_commission numeric;
  v_ttc numeric; v_paid numeric; v_stype text;
BEGIN
  IF p_flow = 'rent' THEN
    SELECT owner_id, COALESCE(p_amount, price) INTO v_owner, v_amount FROM public.properties WHERE id = p_ref_id;
    IF v_owner IS NOT NULL THEN v_rate := public.resolve_service_commission_rate(v_owner, 'location', 0); END IF;

  ELSIF p_flow = 'restaurant' THEN
    SELECT user_id INTO v_owner FROM public.professional_services WHERE id = p_ref_id;
    v_amount := COALESCE(p_amount, 0);   -- sous-total PLATS (hors frais de livraison)
    IF v_owner IS NOT NULL THEN v_rate := COALESCE(public.resolve_service_commission_rate(v_owner, 'restaurant', 15), 15); END IF;

  ELSIF p_flow = 'quote' THEN
    SELECT ps.user_id, st.code, COALESCE(st.commission_rate, 10), q.total_amount
      INTO v_provider, v_code, v_def, v_amount
    FROM public.service_quotes q
    JOIN public.professional_services ps ON ps.id = q.professional_service_id
    JOIN public.service_types st ON st.id = ps.service_type_id
    WHERE q.id = p_ref_id;
    IF v_provider IS NOT NULL THEN v_rate := public.resolve_service_commission_rate(v_provider, v_code, v_def); END IF;

  ELSIF p_flow IN ('artisan_deposit', 'artisan_balance') THEN
    SELECT i.service_type, q.total_ttc, i.amount_paid
      INTO v_stype, v_ttc, v_paid
    FROM public.artisan_interventions i
    JOIN public.artisan_quotes q ON q.id = i.quote_id
    WHERE i.id = p_ref_id;
    IF p_flow = 'artisan_deposit' THEN
      v_amount := round(COALESCE(v_ttc,0) * LEAST(GREATEST(COALESCE(p_deposit_pct,30),0),100) / 100.0);
    ELSE
      v_amount := GREATEST(0, COALESCE(v_ttc,0) - COALESCE(v_paid,0));
    END IF;
    SELECT COALESCE(commission_rate, 5) INTO v_rate FROM public.service_types WHERE code = v_stype;
    v_rate := COALESCE(v_rate, 5);

  ELSE
    RAISE EXCEPTION 'FLOW_INCONNU';
  END IF;

  v_amount := GREATEST(0, COALESCE(v_amount, 0));
  v_commission := round(v_amount * COALESCE(v_rate, 0) / 100.0);
  RETURN jsonb_build_object(
    'flow', p_flow, 'amount', v_amount, 'rate', COALESCE(v_rate,0),
    'commission', v_commission, 'total', v_amount + v_commission);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.preview_commission(text, uuid, numeric, numeric) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.preview_commission(text, uuid, numeric, numeric) TO authenticated, service_role;

SELECT 'preview_commission créé : le client voit montant + commission = total avant paiement (calcul serveur exact).' AS status;
