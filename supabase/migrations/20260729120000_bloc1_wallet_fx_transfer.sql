-- ============================================================================
-- BLOC 1 — Transfert wallet cross-devise : convertir via la SANTÉ FX, jamais 1:1.
-- ----------------------------------------------------------------------------
-- Constat : execute_atomic_wallet_transfer débitait p_amount (devise expéditeur) et créditait
-- p_amount (devise destinataire) SANS conversion (1000 XOF -> 1000 GNF).
-- Décision Thierno : CONVERSION (pas refus), via le système FX LIVE = currency_exchange_rates
-- (taux BCRG scrapés, seul système alimenté ; fx_quote/fx_rates_ledger est vide, exchange_rates mort).
-- Santé AVANT conversion : taux présent + frais (< fx_config.fx_stale_hours) + DANS fx_pair_bounds.
-- Sinon EXCEPTION FX_INDISPONIBLE (aucun débit). Taux + source + horodatage VERROUILLÉS dans
-- enhanced_transactions.metadata (le crédit est immuable même si le taux bouge après).
-- Formule = amount * rate (ROUND 2) — IDENTIQUE à credit_user_wallet_safe, AUCUNE nouvelle formule.
-- ============================================================================

-- ── Helper canonique : résout un taux SAIN et convertit, sinon lève FX_INDISPONIBLE ──
-- Source unique de la conversion wallet. Motif direct/inverse/pivot-USD ISO credit_user_wallet_safe,
-- ÉTENDU des gardes de santé (fraîcheur fx_config + bornes fx_pair_bounds) voulues par le PDG.
CREATE OR REPLACE FUNCTION public.wallet_fx_resolve(
  p_from_currency text, p_to_currency text, p_amount numeric
)
RETURNS TABLE(converted_amount numeric, rate_used numeric, rate_source text, rate_fetched_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_from text := upper(nullif(btrim(p_from_currency), ''));
  v_to   text := upper(nullif(btrim(p_to_currency), ''));
  v_rate numeric; v_source text; v_fetched timestamptz;
  v_from_usd numeric; v_usd_to numeric; v_ret1 timestamptz; v_ret2 timestamptz;
  v_stale_hours numeric;
  v_min numeric; v_max numeric;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'Montant invalide'; END IF;

  -- Identité : même devise (ou devise inconnue) → pas de conversion.
  IF v_from IS NULL OR v_to IS NULL OR v_from = v_to THEN
    converted_amount := p_amount; rate_used := 1; rate_source := 'identity'; rate_fetched_at := now();
    RETURN NEXT; RETURN;
  END IF;

  SELECT COALESCE((public.fx_active_config()).fx_stale_hours, 24) INTO v_stale_hours;
  v_stale_hours := COALESCE(v_stale_hours, 24);

  -- Taux DIRECT ou INVERSE, le plus frais actif (motif ISO code argent live).
  SELECT CASE WHEN cer.from_currency = v_from THEN cer.rate ELSE 1.0 / NULLIF(cer.rate, 0) END,
         cer.source_type, cer.retrieved_at
    INTO v_rate, v_source, v_fetched
  FROM public.currency_exchange_rates cer
  WHERE ((cer.from_currency = v_from AND cer.to_currency = v_to)
      OR (cer.from_currency = v_to AND cer.to_currency = v_from))
    AND cer.is_active = true
  ORDER BY cer.retrieved_at DESC LIMIT 1;

  -- Pivot USD si pas de direct/inverse.
  IF v_rate IS NULL OR v_rate <= 0 THEN
    SELECT CASE WHEN cer.from_currency = v_from THEN cer.rate ELSE 1.0 / NULLIF(cer.rate, 0) END, cer.retrieved_at
      INTO v_from_usd, v_ret1 FROM public.currency_exchange_rates cer
      WHERE ((cer.from_currency = v_from AND cer.to_currency = 'USD') OR (cer.from_currency = 'USD' AND cer.to_currency = v_from))
        AND cer.is_active = true ORDER BY cer.retrieved_at DESC LIMIT 1;
    SELECT CASE WHEN cer.from_currency = 'USD' THEN cer.rate ELSE 1.0 / NULLIF(cer.rate, 0) END, cer.retrieved_at
      INTO v_usd_to, v_ret2 FROM public.currency_exchange_rates cer
      WHERE ((cer.from_currency = 'USD' AND cer.to_currency = v_to) OR (cer.from_currency = v_to AND cer.to_currency = 'USD'))
        AND cer.is_active = true ORDER BY cer.retrieved_at DESC LIMIT 1;
    IF v_from_usd IS NOT NULL AND v_from_usd > 0 AND v_usd_to IS NOT NULL AND v_usd_to > 0 THEN
      v_rate := v_from_usd * v_usd_to;
      v_source := 'usd_pivot';
      v_fetched := LEAST(v_ret1, v_ret2);   -- fraîcheur = la plus faible des deux jambes
    END IF;
  END IF;

  -- SANTÉ 1/3 : présent.
  IF v_rate IS NULL OR v_rate <= 0 THEN
    RAISE EXCEPTION 'FX_INDISPONIBLE: conversion %→% momentanément indisponible (taux introuvable)', v_from, v_to;
  END IF;
  -- SANTÉ 2/3 : frais (péremption fx_config.fx_stale_hours).
  IF v_fetched IS NULL OR v_fetched < now() - (v_stale_hours * interval '1 hour') THEN
    RAISE EXCEPTION 'FX_INDISPONIBLE: taux %→% périmé (dernière maj %, seuil %h)', v_from, v_to, v_fetched, v_stale_hours;
  END IF;
  -- SANTÉ 3/3 : dans les bornes fx_pair_bounds (si une borne existe pour la paire, directe ou inverse).
  SELECT b.min_rate, b.max_rate INTO v_min, v_max FROM public.fx_pair_bounds b WHERE b.pair = v_from || '/' || v_to;
  IF FOUND THEN
    IF v_rate < v_min OR v_rate > v_max THEN
      RAISE EXCEPTION 'FX_INDISPONIBLE: taux %→% hors bornes (% hors [%,%])', v_from, v_to, v_rate, v_min, v_max;
    END IF;
  ELSE
    SELECT b.min_rate, b.max_rate INTO v_min, v_max FROM public.fx_pair_bounds b WHERE b.pair = v_to || '/' || v_from;
    IF FOUND AND ((1.0 / NULLIF(v_rate, 0)) < v_min OR (1.0 / NULLIF(v_rate, 0)) > v_max) THEN
      RAISE EXCEPTION 'FX_INDISPONIBLE: taux %→% hors bornes (inverse % hors [%,%])', v_from, v_to, (1.0 / NULLIF(v_rate, 0)), v_min, v_max;
    END IF;
  END IF;

  converted_amount := ROUND(p_amount * v_rate, 2);
  rate_used := v_rate;
  rate_source := COALESCE(v_source, 'currency_exchange_rates');
  rate_fetched_at := v_fetched;
  RETURN NEXT;
END;
$$;
REVOKE ALL ON FUNCTION public.wallet_fx_resolve(text, text, numeric) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.wallet_fx_resolve(text, text, numeric) TO authenticated, service_role;

-- ── execute_atomic_wallet_transfer : branche cross-devise (convertit + verrouille le taux) ──
-- MÊME devise → comportement inchangé au centime. Devises différentes → wallet_fx_resolve
-- (santé + conversion) puis crédit du montant CONVERTI, taux/source/horodatage écrits dans metadata.
CREATE OR REPLACE FUNCTION public.execute_atomic_wallet_transfer(
  p_sender_id uuid, p_receiver_id uuid, p_amount numeric, p_description text,
  p_sender_wallet_id bigint, p_recipient_wallet_id bigint,
  p_sender_balance_before numeric, p_recipient_balance_before numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_tx_id uuid := gen_random_uuid();
  v_sender_balance numeric; v_recipient_balance numeric; v_sender_blocked boolean;
  v_recipient_cur text; v_sender_cur text; v_credited numeric; v_amount_gnf numeric;
  v_credit_amount numeric; v_rate numeric; v_source text; v_fetched timestamptz; v_fx boolean := false;
  v_meta jsonb;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'Montant invalide'; END IF;

  IF p_sender_wallet_id <= p_recipient_wallet_id THEN
    PERFORM 1 FROM wallets WHERE id = p_sender_wallet_id FOR UPDATE;
    PERFORM 1 FROM wallets WHERE id = p_recipient_wallet_id FOR UPDATE;
  ELSE
    PERFORM 1 FROM wallets WHERE id = p_recipient_wallet_id FOR UPDATE;
    PERFORM 1 FROM wallets WHERE id = p_sender_wallet_id FOR UPDATE;
  END IF;

  SELECT balance, COALESCE(is_blocked,false), currency INTO v_sender_balance, v_sender_blocked, v_sender_cur
  FROM wallets WHERE id = p_sender_wallet_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Sender wallet not found'; END IF;
  IF v_sender_blocked THEN RAISE EXCEPTION 'Sender wallet blocked'; END IF;

  SELECT balance, currency INTO v_recipient_balance, v_recipient_cur FROM wallets WHERE id = p_recipient_wallet_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Recipient wallet not found'; END IF;

  IF v_sender_balance < p_amount THEN RAISE EXCEPTION 'Solde insuffisant'; END IF;

  -- 🛡️ LIMITE CUMULÉE jour/mois sur le DÉBIT (devise expéditeur → GNF).
  v_amount_gnf := public.convert_to_gnf(p_amount, COALESCE(v_sender_cur,'GNF'));
  PERFORM public.enforce_transfer_limit(p_sender_id, v_amount_gnf);

  -- 💱 CONVERSION cross-devise via la santé FX (lève FX_INDISPONIBLE si taux malsain → aucun débit).
  IF v_sender_cur IS NOT NULL AND v_recipient_cur IS NOT NULL AND v_sender_cur <> v_recipient_cur THEN
    SELECT converted_amount, rate_used, rate_source, rate_fetched_at
      INTO v_credit_amount, v_rate, v_source, v_fetched
      FROM public.wallet_fx_resolve(v_sender_cur, v_recipient_cur, p_amount);
    v_fx := true;
  ELSE
    v_credit_amount := p_amount;   -- même devise : crédit = débit (inchangé)
  END IF;

  v_credited := public.apply_wallet_cap_split(p_receiver_id, p_recipient_wallet_id, v_recipient_balance, v_credit_amount, v_recipient_cur, 'transfer_in', v_tx_id::text);

  UPDATE wallets SET balance = v_sender_balance - p_amount, updated_at = now() WHERE id = p_sender_wallet_id;
  UPDATE wallets SET balance = v_recipient_balance + v_credited, updated_at = now() WHERE id = p_recipient_wallet_id;

  -- Metadata : base inchangée pour le même-devise ; VERROU du taux si conversion.
  v_meta := jsonb_build_object('description', p_description, 'atomic', true, 'transaction_type', 'transfer',
    'credited', v_credited, 'quarantined', (v_credit_amount - v_credited));
  IF v_fx THEN
    v_meta := v_meta || jsonb_build_object('fx', true, 'credit_amount', v_credit_amount,
      'sender_currency', v_sender_cur, 'receiver_currency', v_recipient_cur,
      'rate_used', v_rate, 'exchange_rate_source', v_source, 'rate_fetched_at', v_fetched);
  END IF;

  INSERT INTO enhanced_transactions (id, sender_id, receiver_id, amount, method, status, currency, metadata)
  VALUES (v_tx_id, p_sender_id, p_receiver_id, p_amount, 'wallet', 'completed', v_sender_cur, v_meta);

  BEGIN
    INSERT INTO public.wallet_logs (user_id, action, amount, currency, transaction_id, status, metadata)
    VALUES (p_sender_id, 'transfer', v_amount_gnf, 'GNF', v_tx_id, 'completed', jsonb_build_object('atomic', true, 'national', NOT v_fx, 'fx', v_fx));
  EXCEPTION WHEN OTHERS THEN NULL; END;

  RETURN jsonb_build_object('success', true, 'transaction_id', v_tx_id, 'quarantined', (v_credit_amount - v_credited),
    'fx', v_fx, 'credit_amount', v_credit_amount, 'rate_used', v_rate);
END;
$function$;
REVOKE ALL ON FUNCTION public.execute_atomic_wallet_transfer(uuid,uuid,numeric,text,bigint,bigint,numeric,numeric) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.execute_atomic_wallet_transfer(uuid,uuid,numeric,text,bigint,bigint,numeric,numeric) TO service_role;
