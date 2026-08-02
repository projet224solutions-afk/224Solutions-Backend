-- ═══════════════════════════════════════════════════════════════════════════════
-- PRESTATIONS DE SERVICE — ZÉRO COMMISSION (modèle ABONNEMENT)
-- ═══════════════════════════════════════════════════════════════════════════════
-- Décision PDG : les prestataires de service paient un ABONNEMENT (plan gratuit limité par
-- métier, abonnement au-delà). Prélever EN PLUS une commission par devis = double facturation.
-- → AUCUNE commission plateforme sur les devis de prestation (`service_quotes`).
--
-- PÉRIMÈTRE STRICT : ne touche QUE le chemin `service_quotes` (pay_quote_atomic + preview 'quote').
--   • La commission des COMMERÇANTS produits (apply_platform_commission / pay_with_commission /
--     calculate_purchase_commission) reste INCHANGÉE — autres fonctions, non référencées ici.
--   • Les flux rent / restaurant / artisan de preview_commission restent INCHANGÉS (autres modules,
--     décision séparée).
--   • release_quote_atomic crédite déjà 100 % de total_amount, sans commission — inchangé.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) pay_quote_atomic : le client paie EXACTEMENT total_amount, le prestataire reçoit 100 %,
--    RIEN au PDG. Atomicité + idempotence (clé `quote-pay-<id>`) préservées.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.pay_quote_atomic(p_actor_user_id uuid, p_quote_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE q public.service_quotes%ROWTYPE; v_provider uuid; v_res jsonb; v_got numeric;
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

  -- 💡 ABONNEMENT = seule source de revenu plateforme sur ce périmètre → 0 commission.
  -- Le client est débité EXACTEMENT total_amount (plus de « + commission »).
  PERFORM public.wallet_debit_internal(
    p_actor_user_id, q.total_amount,
    'Paiement devis : ' || q.title, 'quote-pay-' || p_quote_id::text);

  IF q.escrow THEN
    -- Séquestre : le prestataire est crédité à la LIBÉRATION (release_quote_atomic) — 100 %.
    UPDATE public.service_quotes SET status = 'paid', escrow_status = 'held', paid_at = now(),
      client_user_id = COALESCE(client_user_id, p_actor_user_id) WHERE id = p_quote_id;
    RETURN jsonb_build_object('success', true, 'escrow', true);
  ELSE
    -- Direct : le prestataire reçoit 100 % de total_amount immédiatement.
    v_res := public.credit_user_wallet_safe(v_provider, q.total_amount, 'GNF', 'quote_payment', p_quote_id::text);
    v_got := COALESCE((v_res->>'credited')::numeric,0) + COALESCE((v_res->>'quarantined')::numeric,0);
    IF NOT COALESCE((v_res->>'skipped')::boolean, false) AND v_got <= 0 THEN
      RAISE EXCEPTION 'CREDIT_PRESTATAIRE_ECHOUE (%)', COALESCE(v_res->>'error','?');
    END IF;
    UPDATE public.service_quotes SET status = 'paid', paid_at = now(),
      client_user_id = COALESCE(client_user_id, p_actor_user_id) WHERE id = p_quote_id;
    RETURN jsonb_build_object('success', true, 'escrow', false);
  END IF;
END;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) preview_commission : flow 'quote' (prestations de service) → commission 0.
--    Les autres flux (rent / restaurant / artisan) restent INCHANGÉS.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.preview_commission(p_flow text, p_ref_id uuid, p_amount numeric DEFAULT NULL::numeric, p_deposit_pct numeric DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    v_amount := COALESCE(p_amount, 0);
    IF v_owner IS NOT NULL THEN v_rate := COALESCE(public.resolve_service_commission_rate(v_owner, 'restaurant', 15), 15); END IF;

  ELSIF p_flow = 'quote' THEN
    -- 💡 Prestations de service = modèle ABONNEMENT → AUCUNE commission (rate 0).
    SELECT q.total_amount INTO v_amount
    FROM public.service_quotes q
    WHERE q.id = p_ref_id;
    v_rate := 0;

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
$function$;
