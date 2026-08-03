-- ═══════════════════════════════════════════════════════════════════════════════
-- PRESTATIONS DE SERVICE — FRAIS DE SERVICE 1 % payés par le CLIENT (style Fiverr)
-- ═══════════════════════════════════════════════════════════════════════════════
-- Décision PDG : le prestataire reçoit 100 % de son prix (abonnement = son modèle, inchangé).
-- Le CLIENT paie EN PLUS un frais de service plateforme de 1 % → va au PDG.
-- ⚠️ Ce N'EST PAS l'ancienne commission (retirée en zero_commission, qui ponctionnait le prestataire).
-- Ici : client débité (total + 1 %), prestataire crédité total (100 %), PDG crédité le 1 %.
-- PÉRIMÈTRE STRICT : service_quotes uniquement. Marketplace produits INCHANGÉ (autres fonctions).

CREATE OR REPLACE FUNCTION public.pay_quote_atomic(p_actor_user_id uuid, p_quote_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  q public.service_quotes%ROWTYPE;
  v_provider uuid; v_res jsonb; v_got numeric;
  v_fee_pct numeric := 1;   -- 1 % — frais de service CLIENT (configurable : pdg_settings.service_client_fee_percent)
  v_fee numeric; v_pdg uuid;
BEGIN
  SELECT * INTO q FROM public.service_quotes WHERE id = p_quote_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'QUOTE_NOT_FOUND'; END IF;
  IF q.status IN ('paid','completed') THEN RETURN jsonb_build_object('success', true, 'already', true); END IF;
  IF q.status = 'cancelled' THEN RAISE EXCEPTION 'QUOTE_CANCELLED'; END IF;
  IF COALESCE(q.total_amount,0) <= 0 THEN RAISE EXCEPTION 'BAD_AMOUNT'; END IF;

  SELECT ps.user_id INTO v_provider
  FROM public.professional_services ps
  WHERE ps.id = q.professional_service_id;
  IF v_provider = p_actor_user_id THEN RAISE EXCEPTION 'OWN_QUOTE'; END IF;

  -- Frais de service CLIENT (1 %) → PDG. Le prestataire reçoit toujours 100 % de total_amount.
  v_fee := round(COALESCE(q.total_amount,0) * v_fee_pct / 100.0);
  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;

  -- Le client est débité total_amount + frais de service (jamais caché — affiché avant paiement côté UI).
  PERFORM public.wallet_debit_internal(
    p_actor_user_id, q.total_amount + v_fee,
    'Paiement devis : ' || q.title || ' (+ frais de service 1%)', 'quote-pay-' || p_quote_id::text);

  -- Frais de service → PDG (plateforme), indépendamment de l'escrow.
  IF v_pdg IS NOT NULL AND v_fee > 0 THEN
    PERFORM public.credit_user_wallet_safe(v_pdg, v_fee, 'GNF', 'service_client_fee', p_quote_id::text);
  END IF;

  IF q.escrow THEN
    -- Séquestre : le prestataire est crédité à la LIBÉRATION (release_quote_atomic) — 100 %.
    UPDATE public.service_quotes SET status = 'paid', escrow_status = 'held', paid_at = now(),
      client_user_id = COALESCE(client_user_id, p_actor_user_id) WHERE id = p_quote_id;
    RETURN jsonb_build_object('success', true, 'escrow', true, 'service_fee', v_fee);
  ELSE
    -- Direct : le prestataire reçoit 100 % de total_amount immédiatement.
    v_res := public.credit_user_wallet_safe(v_provider, q.total_amount, 'GNF', 'quote_payment', p_quote_id::text);
    v_got := COALESCE((v_res->>'credited')::numeric,0) + COALESCE((v_res->>'quarantined')::numeric,0);
    IF NOT COALESCE((v_res->>'skipped')::boolean, false) AND v_got <= 0 THEN
      RAISE EXCEPTION 'CREDIT_PRESTATAIRE_ECHOUE (%)', COALESCE(v_res->>'error','?');
    END IF;
    UPDATE public.service_quotes SET status = 'paid', paid_at = now(),
      client_user_id = COALESCE(client_user_id, p_actor_user_id) WHERE id = p_quote_id;
    RETURN jsonb_build_object('success', true, 'escrow', false, 'service_fee', v_fee);
  END IF;
END;
$function$;

-- Aperçu du frais côté UI (affichage transparent avant paiement) — helper lisible par le client.
CREATE OR REPLACE FUNCTION public.preview_quote_service_fee(p_quote_id uuid)
 RETURNS jsonb
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT jsonb_build_object(
    'amount', COALESCE(total_amount,0),
    'fee_percent', 1,
    'service_fee', round(COALESCE(total_amount,0) * 1 / 100.0),
    'total', COALESCE(total_amount,0) + round(COALESCE(total_amount,0) * 1 / 100.0)
  ) FROM public.service_quotes WHERE id = p_quote_id;
$function$;
GRANT EXECUTE ON FUNCTION public.preview_quote_service_fee(uuid) TO authenticated, service_role;
