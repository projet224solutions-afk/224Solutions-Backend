-- ═══════════════════════════════════════════════════════════════════════════
-- 👻 FATOME EXCHANGE V2 — VAGUES 2, 3, 4 (améliore SANS casser, ZÉRO IA)
-- V2 : RÈGLE D'OR — transfert exige un taux OFFICIEL frais (FX_INDISPONIBLE renforcé) ;
--      marketplace/commandes convertis quand même (indicatif, dernier taux connu).
-- V3 : SPREAD facturer-haut/payer-bas figé + récap transparent + taux garanti 10 min.
-- V4 : commandes cross-pays protégées (vendeur payé plein) + revenus FX par corridor.
-- Additif : signatures étendues par paramètres à DÉFAUT → chemins existants byte-identiques.
-- ═══════════════════════════════════════════════════════════════════════════

-- Anti-surcharge : on remplace les anciennes signatures (3 args / 8 args) par les versions
-- à paramètres additionnels. Les appels EXISTANTS (route: 8 args ; interne: 3 args) tombent
-- alors sur les nouvelles fonctions avec leurs DÉFAUTS → chemin renforcé atteint sans changer
-- les appelants. (fonctions appelées via RPC runtime = aucune dépendance DB à casser.)
DROP FUNCTION IF EXISTS public.wallet_fx_resolve(text, text, numeric);
DROP FUNCTION IF EXISTS public.execute_atomic_wallet_transfer(uuid,uuid,numeric,text,bigint,bigint,numeric,numeric);

-- ── V2.1 — wallet_fx_resolve : +p_require_official (DÉFAUT false = non-régressif) ──
-- Un taux OFFICIEL = source_type LIKE 'official%' (banque centrale / peg officiel).
-- 'cross' (pivot USD) et 'fallback_api' NE sont PAS officiels → refus si require_official.
CREATE OR REPLACE FUNCTION public.wallet_fx_resolve(
  p_from text, p_to text, p_amount numeric, p_require_official boolean DEFAULT false)
RETURNS TABLE(converted_amount numeric, rate_used numeric, rate_source text, rate_fetched_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_from text := upper(trim(p_from)); v_to text := upper(trim(p_to));
  v_rate numeric; v_source text; v_fetched timestamptz; v_stype text;
  v_from_usd numeric; v_usd_to numeric; v_ret1 timestamptz; v_ret2 timestamptz;
  v_st1 text; v_st2 text; v_min numeric; v_max numeric; v_stale_hours numeric;
BEGIN
  IF v_from = v_to THEN
    converted_amount := p_amount; rate_used := 1; rate_source := 'identity'; rate_fetched_at := now();
    RETURN NEXT; RETURN;
  END IF;
  SELECT COALESCE((public.fx_active_config()).fx_stale_hours, 24) INTO v_stale_hours;
  v_stale_hours := COALESCE(v_stale_hours, 24);

  -- DIRECT / INVERSE le plus frais. Si require_official, on ne considère QUE les sources officielles.
  SELECT CASE WHEN cer.from_currency = v_from THEN cer.rate ELSE 1.0 / NULLIF(cer.rate, 0) END,
         cer.source, cer.retrieved_at, cer.source_type
    INTO v_rate, v_source, v_fetched, v_stype
  FROM public.currency_exchange_rates cer
  WHERE cer.is_active
    AND ((cer.from_currency = v_from AND cer.to_currency = v_to)
      OR (cer.from_currency = v_to AND cer.to_currency = v_from))
    AND (NOT p_require_official OR cer.source_type LIKE 'official%')
  ORDER BY cer.retrieved_at DESC NULLS LAST LIMIT 1;

  -- PIVOT USD si pas de directe (chaque jambe respecte l'exigence officielle).
  IF v_rate IS NULL OR v_rate <= 0 THEN
    SELECT CASE WHEN cer.from_currency = v_from THEN cer.rate ELSE 1.0 / NULLIF(cer.rate, 0) END,
           cer.retrieved_at, cer.source_type
      INTO v_from_usd, v_ret1, v_st1 FROM public.currency_exchange_rates cer
    WHERE cer.is_active AND ((cer.from_currency = v_from AND cer.to_currency = 'USD')
       OR (cer.from_currency = 'USD' AND cer.to_currency = v_from))
      AND (NOT p_require_official OR cer.source_type LIKE 'official%')
    ORDER BY cer.retrieved_at DESC NULLS LAST LIMIT 1;
    SELECT CASE WHEN cer.from_currency = 'USD' THEN cer.rate ELSE 1.0 / NULLIF(cer.rate, 0) END,
           cer.retrieved_at, cer.source_type
      INTO v_usd_to, v_ret2, v_st2 FROM public.currency_exchange_rates cer
    WHERE cer.is_active AND ((cer.from_currency = 'USD' AND cer.to_currency = v_to)
       OR (cer.from_currency = v_to AND cer.to_currency = 'USD'))
      AND (NOT p_require_official OR cer.source_type LIKE 'official%')
    ORDER BY cer.retrieved_at DESC NULLS LAST LIMIT 1;
    IF v_from_usd IS NOT NULL AND v_usd_to IS NOT NULL AND v_from_usd > 0 AND v_usd_to > 0 THEN
      v_rate := v_from_usd * v_usd_to;
      v_fetched := LEAST(v_ret1, v_ret2);
      v_source := 'pivot_usd'; v_stype := 'official_cross';
    END IF;
  END IF;

  IF v_rate IS NULL OR v_rate <= 0 THEN
    IF p_require_official THEN
      RAISE EXCEPTION 'FX_INDISPONIBLE: taux officiel %→% indisponible, réessayez bientôt', v_from, v_to;
    END IF;
    RAISE EXCEPTION 'FX_INDISPONIBLE: conversion %→% momentanément indisponible (taux introuvable)', v_from, v_to;
  END IF;
  -- Fraîcheur stricte.
  IF v_fetched IS NULL OR v_fetched < now() - (v_stale_hours * interval '1 hour') THEN
    RAISE EXCEPTION 'FX_INDISPONIBLE: taux %→% périmé (dernière maj %, seuil %h)', v_from, v_to, v_fetched, v_stale_hours;
  END IF;
  -- Bornes fx_pair_bounds (directe puis inverse).
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
  rate_used := v_rate; rate_source := COALESCE(v_source, 'currency_exchange_rates'); rate_fetched_at := v_fetched;
  RETURN NEXT;
END;
$$;
REVOKE ALL ON FUNCTION public.wallet_fx_resolve(text, text, numeric, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.wallet_fx_resolve(text, text, numeric, boolean) TO authenticated, service_role;

-- ── V2.2 — CONVERTISSEUR INDICATIF (marketplace/commandes) : ne BLOQUE JAMAIS ──
-- Renvoie toujours un taux (dernier connu, même cross/périmé), avec is_official + âge +
-- available. Si vraiment rien → available=false (l'appelant retombe sur la devise native).
CREATE OR REPLACE FUNCTION public.fx_convert_indicative(p_from text, p_to text, p_amount numeric)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_from text := upper(trim(p_from)); v_to text := upper(trim(p_to));
  v_rate numeric; v_stype text; v_fetched timestamptz; v_from_usd numeric; v_usd_to numeric;
BEGIN
  IF v_from = v_to THEN
    RETURN jsonb_build_object('available', true, 'rate', 1, 'converted', p_amount,
      'is_official', true, 'age_hours', 0);
  END IF;
  SELECT CASE WHEN cer.from_currency = v_from THEN cer.rate ELSE 1.0 / NULLIF(cer.rate, 0) END,
         cer.source_type, cer.retrieved_at
    INTO v_rate, v_stype, v_fetched
  FROM public.currency_exchange_rates cer
  WHERE cer.is_active AND ((cer.from_currency = v_from AND cer.to_currency = v_to)
     OR (cer.from_currency = v_to AND cer.to_currency = v_from))
  ORDER BY cer.retrieved_at DESC NULLS LAST LIMIT 1;

  IF v_rate IS NULL OR v_rate <= 0 THEN
    SELECT CASE WHEN cer.from_currency = v_from THEN cer.rate ELSE 1.0 / NULLIF(cer.rate, 0) END
      INTO v_from_usd FROM public.currency_exchange_rates cer
    WHERE cer.is_active AND ((cer.from_currency = v_from AND cer.to_currency='USD') OR (cer.from_currency='USD' AND cer.to_currency=v_from))
    ORDER BY cer.retrieved_at DESC NULLS LAST LIMIT 1;
    SELECT CASE WHEN cer.from_currency = 'USD' THEN cer.rate ELSE 1.0 / NULLIF(cer.rate, 0) END
      INTO v_usd_to FROM public.currency_exchange_rates cer
    WHERE cer.is_active AND ((cer.from_currency='USD' AND cer.to_currency=v_to) OR (cer.from_currency=v_to AND cer.to_currency='USD'))
    ORDER BY cer.retrieved_at DESC NULLS LAST LIMIT 1;
    IF v_from_usd > 0 AND v_usd_to > 0 THEN v_rate := v_from_usd * v_usd_to; v_stype := 'cross'; END IF;
  END IF;

  IF v_rate IS NULL OR v_rate <= 0 THEN
    RETURN jsonb_build_object('available', false); -- l'appelant retombe sur la devise native
  END IF;
  RETURN jsonb_build_object('available', true, 'rate', v_rate, 'converted', ROUND(p_amount * v_rate, 2),
    'is_official', COALESCE(v_stype LIKE 'official%', false),
    'age_hours', ROUND(EXTRACT(EPOCH FROM (now() - COALESCE(v_fetched, now()))) / 3600));
END;
$$;
REVOKE ALL ON FUNCTION public.fx_convert_indicative(text, text, numeric) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fx_convert_indicative(text, text, numeric) TO authenticated, service_role;

-- ── V3.1 — Quotes de transfert : SPREAD figé + taux garanti 10 min ──────────
CREATE TABLE IF NOT EXISTS public.fx_transfer_quotes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  from_currency text NOT NULL,
  to_currency text NOT NULL,
  amount numeric NOT NULL CHECK (amount > 0),
  official_rate numeric NOT NULL CHECK (official_rate > 0),
  margin_fraction numeric NOT NULL CHECK (margin_fraction >= 0),
  buy_rate numeric NOT NULL,        -- facturé expéditeur = officiel × (1+marge)
  sell_rate numeric NOT NULL,       -- payé destinataire = officiel × (1−marge)
  amount_received numeric NOT NULL, -- montant crédité au destinataire (devise dest.)
  spread_amount numeric NOT NULL,   -- revenu (devise dest.)
  spread_currency text NOT NULL,
  created_by uuid,
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.fx_transfer_quotes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS fxtq_own ON public.fx_transfer_quotes;
CREATE POLICY fxtq_own ON public.fx_transfer_quotes FOR SELECT TO authenticated USING (created_by = auth.uid());

-- fx_quote_transfer : cote le transfert (taux officiel frais OBLIGATOIRE — règle d'or) et
-- fige buy/sell + récap. Garanti 10 min. Retourne le récap transparent pour l'UI.
CREATE OR REPLACE FUNCTION public.fx_quote_transfer(p_from text, p_to text, p_amount numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_from text := upper(trim(p_from)); v_to text := upper(trim(p_to));
  v_conv numeric; v_rate numeric; v_src text; v_fetched timestamptz;
  v_margin numeric; v_buy numeric; v_sell numeric; v_received numeric; v_at_official numeric;
  v_spread numeric; v_id uuid;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'AMOUNT_INVALID'; END IF;
  -- RÈGLE D'OR : taux officiel frais obligatoire (sinon FX_INDISPONIBLE → transfert impossible).
  SELECT converted_amount, rate_used, rate_source, rate_fetched_at
    INTO v_conv, v_rate, v_src, v_fetched
    FROM public.wallet_fx_resolve(v_from, v_to, p_amount, true);

  v_margin := public.fx_effective_margin_fraction(v_from || '/' || v_to);
  v_buy  := ROUND(v_rate * (1 + v_margin), 8);
  v_sell := ROUND(v_rate * (1 - v_margin), 8);
  v_at_official := ROUND(p_amount * v_rate, 2);
  v_received := ROUND(p_amount * v_sell, 2);        -- le destinataire reçoit au sell_rate
  v_spread := ROUND(v_at_official - v_received, 2);  -- l'écart = revenu (devise destinataire)

  INSERT INTO public.fx_transfer_quotes (from_currency, to_currency, amount, official_rate,
    margin_fraction, buy_rate, sell_rate, amount_received, spread_amount, spread_currency,
    created_by, expires_at)
  VALUES (v_from, v_to, p_amount, v_rate, v_margin, v_buy, v_sell, v_received, v_spread, v_to,
    auth.uid(), now() + interval '10 minutes')
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('quote_id', v_id, 'from', v_from, 'to', v_to, 'amount', p_amount,
    'official_rate', v_rate, 'buy_rate', v_buy, 'sell_rate', v_sell, 'margin_percent', ROUND(v_margin * 100, 4),
    'amount_received', v_received, 'spread_amount', v_spread, 'spread_currency', v_to,
    'source', v_src, 'rate_fetched_at', v_fetched, 'guaranteed_until', (now() + interval '10 minutes'));
END;
$$;
REVOKE ALL ON FUNCTION public.fx_quote_transfer(text, text, numeric) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fx_quote_transfer(text, text, numeric) TO authenticated, service_role;

-- ── V3.2 — execute_atomic_wallet_transfer : +p_quote_id (DÉFAUT NULL = inchangé) ──
-- Avec quote_id : applique le SELL_RATE figé au crédit + crédite le SPREAD au coffre PDG
-- (record_pdg_revenue, circuit EXISTANT), tout DANS la transaction atomique. Sans quote_id :
-- comportement actuel byte-identique.
CREATE OR REPLACE FUNCTION public.execute_atomic_wallet_transfer(
  p_sender_id uuid, p_receiver_id uuid, p_amount numeric, p_description text,
  p_sender_wallet_id bigint, p_recipient_wallet_id bigint,
  p_sender_balance_before numeric, p_recipient_balance_before numeric,
  p_quote_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_tx_id uuid := gen_random_uuid();
  v_sender_balance numeric; v_recipient_balance numeric; v_sender_blocked boolean;
  v_recipient_cur text; v_sender_cur text; v_credited numeric; v_amount_gnf numeric;
  v_credit_amount numeric; v_rate numeric; v_source text; v_fetched timestamptz; v_fx boolean := false;
  v_meta jsonb; v_q public.fx_transfer_quotes%ROWTYPE; v_spread numeric := 0;
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

  v_amount_gnf := public.convert_to_gnf(p_amount, COALESCE(v_sender_cur,'GNF'));
  PERFORM public.enforce_transfer_limit(p_sender_id, v_amount_gnf);

  IF v_sender_cur IS NOT NULL AND v_recipient_cur IS NOT NULL AND v_sender_cur <> v_recipient_cur THEN
    IF p_quote_id IS NOT NULL THEN
      -- SPREAD figé : consommer le devis (10 min), appliquer sell_rate + créditer le spread au coffre.
      SELECT * INTO v_q FROM public.fx_transfer_quotes WHERE id = p_quote_id FOR UPDATE;
      IF NOT FOUND THEN RAISE EXCEPTION 'FX_QUOTE_INTROUVABLE'; END IF;
      IF v_q.consumed_at IS NOT NULL THEN RAISE EXCEPTION 'FX_QUOTE_DEJA_UTILISEE'; END IF;
      IF v_q.expires_at < now() THEN RAISE EXCEPTION 'FX_QUOTE_EXPIREE'; END IF;
      IF upper(v_q.from_currency) <> upper(v_sender_cur) OR upper(v_q.to_currency) <> upper(v_recipient_cur)
         OR v_q.amount <> p_amount THEN RAISE EXCEPTION 'FX_QUOTE_INCOHERENTE'; END IF;
      v_credit_amount := v_q.amount_received;  -- sell_rate figé
      v_rate := v_q.sell_rate; v_source := 'quote:' || v_q.id; v_fetched := v_q.created_at;
      v_spread := v_q.spread_amount;
      UPDATE public.fx_transfer_quotes SET consumed_at = now() WHERE id = p_quote_id;
    ELSE
      -- Sans devis : conversion officielle fraîche (règle d'or), sans spread (chemin historique renforcé).
      SELECT converted_amount, rate_used, rate_source, rate_fetched_at
        INTO v_credit_amount, v_rate, v_source, v_fetched
        FROM public.wallet_fx_resolve(v_sender_cur, v_recipient_cur, p_amount, true);
    END IF;
    v_fx := true;
  ELSE
    v_credit_amount := p_amount;
  END IF;

  v_credited := public.apply_wallet_cap_split(p_receiver_id, p_recipient_wallet_id, v_recipient_balance, v_credit_amount, v_recipient_cur, 'transfer_in', v_tx_id::text);

  UPDATE wallets SET balance = v_sender_balance - p_amount, updated_at = now() WHERE id = p_sender_wallet_id;
  UPDATE wallets SET balance = v_recipient_balance + v_credited, updated_at = now() WHERE id = p_recipient_wallet_id;

  v_meta := jsonb_build_object('description', p_description, 'atomic', true, 'transaction_type', 'transfer',
    'credited', v_credited, 'quarantined', (v_credit_amount - v_credited));
  IF v_fx THEN
    v_meta := v_meta || jsonb_build_object('fx', true, 'credit_amount', v_credit_amount,
      'sender_currency', v_sender_cur, 'receiver_currency', v_recipient_cur,
      'rate_used', v_rate, 'exchange_rate_source', v_source, 'rate_fetched_at', v_fetched);
    IF p_quote_id IS NOT NULL THEN
      v_meta := v_meta || jsonb_build_object('quote_id', p_quote_id, 'spread_amount', v_spread,
        'buy_rate', v_q.buy_rate, 'sell_rate', v_q.sell_rate, 'official_rate', v_q.official_rate);
    END IF;
  END IF;

  INSERT INTO enhanced_transactions (id, sender_id, receiver_id, amount, method, status, currency, metadata)
  VALUES (v_tx_id, p_sender_id, p_receiver_id, p_amount, 'wallet', 'completed', v_sender_cur, v_meta);

  -- SPREAD → coffre PDG via le circuit de revenus EXISTANT (idempotent par transaction).
  IF p_quote_id IS NOT NULL AND v_spread > 0 THEN
    PERFORM public.record_pdg_revenue('fx_spread', v_spread, ROUND(v_q.margin_fraction * 100, 4),
      v_tx_id, p_sender_id, NULL,
      jsonb_build_object('corridor', v_sender_cur || '/' || v_recipient_cur, 'quote_id', p_quote_id,
        'official_rate', v_q.official_rate, 'amount', p_amount),
      v_q.spread_currency);
  END IF;

  BEGIN
    INSERT INTO public.wallet_logs (user_id, action, amount, currency, transaction_id, status, metadata)
    VALUES (p_sender_id, 'transfer', v_amount_gnf, 'GNF', v_tx_id, 'completed', jsonb_build_object('atomic', true, 'national', NOT v_fx, 'fx', v_fx));
  EXCEPTION WHEN OTHERS THEN NULL; END;

  RETURN jsonb_build_object('success', true, 'transaction_id', v_tx_id, 'quarantined', (v_credit_amount - v_credited),
    'fx', v_fx, 'credit_amount', v_credit_amount, 'rate_used', v_rate, 'spread_amount', v_spread);
END;
$function$;
REVOKE ALL ON FUNCTION public.execute_atomic_wallet_transfer(uuid,uuid,numeric,text,bigint,bigint,numeric,numeric,uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.execute_atomic_wallet_transfer(uuid,uuid,numeric,text,bigint,bigint,numeric,numeric,uuid) TO service_role;

-- ── V4.1 — Conversion COMMANDE cross-pays : acheteur au buy_rate, vendeur PLEIN ─
-- L'acheteur (pays A) voit son prix au buy_rate ; le vendeur (pays B) est crédité SON prix
-- PLEIN dans SA devise ; l'écart = revenu. Taux FIGÉ à la commande. Taux officiel absent →
-- dernier taux connu + marge de SÉCURITÉ élargie (fx_config, jamais 224Solutions à perte).
ALTER TABLE public.fx_config ADD COLUMN IF NOT EXISTS fx_order_safety_margin_percent numeric NOT NULL DEFAULT 5
  CHECK (fx_order_safety_margin_percent >= 0 AND fx_order_safety_margin_percent <= 50);

CREATE OR REPLACE FUNCTION public.fx_order_convert(p_buyer_cur text, p_vendor_cur text, p_vendor_price numeric)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_bc text := upper(trim(p_buyer_cur)); v_vc text := upper(trim(p_vendor_cur));
  v_ind jsonb; v_rate numeric; v_official boolean; v_margin numeric; v_safety numeric;
  v_buyer_charge numeric; v_spread numeric; v_eff_margin numeric;
BEGIN
  IF v_bc = v_vc THEN
    RETURN jsonb_build_object('buyer_charge', p_vendor_price, 'vendor_receives', p_vendor_price,
      'buyer_currency', v_bc, 'vendor_currency', v_vc, 'rate', 1, 'spread', 0, 'is_official', true);
  END IF;
  -- Taux vendeur→acheteur (prix vendeur exprimé dans la devise acheteur).
  v_ind := public.fx_convert_indicative(v_vc, v_bc, p_vendor_price);
  IF NOT (v_ind->>'available')::boolean THEN
    RETURN jsonb_build_object('available', false); -- l'appelant garde la devise native (repli)
  END IF;
  v_rate := (v_ind->>'rate')::numeric;
  v_official := (v_ind->>'is_official')::boolean;
  v_margin := public.fx_effective_margin_fraction(v_vc || '/' || v_bc);
  SELECT COALESCE((public.fx_active_config()).fx_order_safety_margin_percent, 5) / 100.0 INTO v_safety;
  -- Taux officiel absent → marge de sécurité élargie (max(marge paire, marge sécurité)).
  v_eff_margin := CASE WHEN v_official THEN v_margin ELSE GREATEST(v_margin, v_safety) END;
  v_buyer_charge := ROUND(p_vendor_price * v_rate * (1 + v_eff_margin), 2); -- facturé HAUT
  v_spread := ROUND(v_buyer_charge - ROUND(p_vendor_price * v_rate, 2), 2); -- revenu (devise acheteur)
  RETURN jsonb_build_object('available', true, 'buyer_charge', v_buyer_charge,
    'vendor_receives', p_vendor_price,          -- le vendeur touche SON prix plein (jamais à perte)
    'buyer_currency', v_bc, 'vendor_currency', v_vc, 'rate', v_rate,
    'margin_percent', ROUND(v_eff_margin * 100, 4), 'spread', v_spread, 'spread_currency', v_bc,
    'is_official', v_official, 'safety_applied', NOT v_official);
END;
$$;
REVOKE ALL ON FUNCTION public.fx_order_convert(text, text, numeric) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fx_order_convert(text, text, numeric) TO authenticated, service_role;

-- ── V4.2 — Revenus FX par corridor (dashboard PDG) ──────────────────────────
CREATE OR REPLACE FUNCTION public.fx_revenue_by_corridor(p_since timestamptz DEFAULT now() - interval '30 days')
RETURNS TABLE(corridor text, currency text, total numeric, nb bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(metadata->>'corridor', 'inconnu') AS corridor, currency,
         SUM(amount) AS total, COUNT(*) AS nb
  FROM public.revenus_pdg
  WHERE source_type = 'fx_spread' AND created_at >= p_since
  GROUP BY 1, 2 ORDER BY total DESC;
$$;
REVOKE ALL ON FUNCTION public.fx_revenue_by_corridor(timestamptz) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fx_revenue_by_corridor(timestamptz) TO authenticated, service_role;

-- ── V4.3 — Le coffre PDG accepte le revenu 'fx_spread' (source de revenu FX) ──
-- Le CHECK de revenus_pdg n'énumérait pas 'fx_spread' → le spread ne pouvait pas être
-- crédité. On ÉTEND l'énumération (additif : aucune valeur retirée).
ALTER TABLE public.revenus_pdg DROP CONSTRAINT IF EXISTS revenus_pdg_source_type_check;
ALTER TABLE public.revenus_pdg ADD CONSTRAINT revenus_pdg_source_type_check
  CHECK (source_type = ANY (ARRAY[
    'frais_transaction_wallet','frais_achat_commande','frais_abonnement','abonnement_vendeur',
    'abonnement_service','abonnement_chauffeur','frais_retrait','frais_paiement_lien',
    'event_ticket_commission','fx_spread','autre']));
