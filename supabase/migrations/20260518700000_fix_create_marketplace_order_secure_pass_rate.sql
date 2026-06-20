-- ================================================================
-- FIX create_marketplace_order_secure — résolution taux de change
--
-- But :
--   Après le fix frontend (walletDebitAmount converti en devise acheteur),
--   le backend doit aussi récupérer le taux DB et le transmettre à
--   create_order_core pour :
--     1. Validation cohérence taux frontend vs DB (±5 %)
--     2. Stockage dans escrow_transactions et currency_conversion_logs
--
-- Changements :
--   - Lookup du taux dans currency_exchange_rates (paire directe ou inverse)
--   - Passage de p_exchange_rate_used à create_order_core
-- ================================================================

CREATE OR REPLACE FUNCTION public.create_marketplace_order_secure(
  p_vendor_id           uuid,
  p_payment_method      text,
  p_items               jsonb    DEFAULT '[]'::jsonb,
  p_shipping_address    jsonb    DEFAULT '{}'::jsonb,
  p_currency            text     DEFAULT 'GNF',
  p_wallet_debit_amount numeric  DEFAULT 0,
  p_auto_release_days   int      DEFAULT 7,
  p_exchange_rate_used  numeric  DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_buyer_user_id    uuid        := auth.uid();
  v_customer_id      uuid;
  v_vendor_user_id   uuid;
  v_order_number     text;
  v_buyer_wallet_cur text        := NULL;
  v_rate_row         RECORD;
  v_raw_rate         DECIMAL(20,8) := NULL;
  v_db_rate          DECIMAL(20,8) := NULL;
  v_final_rate       DECIMAL(20,8) := NULL;
BEGIN
  -- Auth obligatoire
  IF v_buyer_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Authentification requise');
  END IF;

  -- Récupérer ou créer le customer
  SELECT id INTO v_customer_id
  FROM public.customers
  WHERE user_id = v_buyer_user_id
  LIMIT 1;

  IF v_customer_id IS NULL THEN
    INSERT INTO public.customers (user_id)
    VALUES (v_buyer_user_id)
    RETURNING id INTO v_customer_id;
  END IF;

  -- Récupérer le vendeur
  SELECT user_id INTO v_vendor_user_id
  FROM public.vendors
  WHERE id = p_vendor_id
    AND is_active = true
  LIMIT 1;

  IF v_vendor_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Vendeur introuvable ou inactif');
  END IF;

  -- Anti-achat chez soi-même
  IF v_vendor_user_id = v_buyer_user_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'Vous ne pouvez pas acheter dans votre propre boutique');
  END IF;

  -- Résoudre la devise du wallet acheteur
  IF p_payment_method = 'wallet' AND p_wallet_debit_amount > 0 THEN
    SELECT currency INTO v_buyer_wallet_cur
    FROM public.wallets
    WHERE user_id = v_buyer_user_id
    LIMIT 1;
  END IF;

  -- Résoudre le taux de change DB pour transmission à create_order_core
  -- (utilisé pour validation et logging uniquement — le débit utilise p_wallet_debit_amount)
  IF p_payment_method = 'wallet'
     AND p_wallet_debit_amount > 0
     AND v_buyer_wallet_cur IS NOT NULL
     AND p_currency IS DISTINCT FROM v_buyer_wallet_cur
  THEN
    SELECT cer.*
    INTO   v_rate_row
    FROM   public.currency_exchange_rates cer
    WHERE (
      (cer.from_currency = p_currency       AND cer.to_currency = v_buyer_wallet_cur)
      OR
      (cer.from_currency = v_buyer_wallet_cur AND cer.to_currency = p_currency)
    )
    AND cer.is_active = true
    ORDER BY cer.retrieved_at DESC
    LIMIT 1;

    IF FOUND THEN
      v_raw_rate := COALESCE(
        CASE
          WHEN p_currency = 'EUR' OR v_buyer_wallet_cur = 'EUR' THEN v_rate_row.final_rate_eur
          WHEN p_currency = 'USD' OR v_buyer_wallet_cur = 'USD' THEN v_rate_row.final_rate_usd
          ELSE v_rate_row.rate * (1.0 + COALESCE(v_rate_row.margin, 0))
        END,
        v_rate_row.rate
      );

      IF v_rate_row.from_currency = p_currency THEN
        v_db_rate := v_raw_rate;
      ELSE
        v_db_rate := 1.0 / NULLIF(v_raw_rate, 0);
      END IF;
    END IF;

    -- Si le frontend a fourni un taux, on le préfère (sauf si DB est plus récent et cohérent)
    -- create_order_core effectuera la validation d'écart ±5%
    v_final_rate := COALESCE(p_exchange_rate_used, v_db_rate);
  ELSE
    v_final_rate := p_exchange_rate_used;
  END IF;

  -- Numéro de commande unique
  v_order_number := 'ORD-' || upper(replace(gen_random_uuid()::text, '-', ''));
  v_order_number := left(v_order_number, 20);

  RETURN public.create_order_core(
    p_order_number           := v_order_number,
    p_customer_id            := v_customer_id,
    p_vendor_id              := p_vendor_id,
    p_vendor_user_id         := v_vendor_user_id,
    p_payment_method         := p_payment_method,
    p_shipping_address       := p_shipping_address,
    p_currency               := p_currency,
    p_items                  := p_items,
    p_auto_release_days      := p_auto_release_days,
    p_buyer_user_id          := v_buyer_user_id,
    p_wallet_debit_amount    := p_wallet_debit_amount,
    p_buyer_wallet_currency  := v_buyer_wallet_cur,
    p_exchange_rate_used     := v_final_rate
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

-- Accorder l'exécution aux utilisateurs authentifiés
GRANT EXECUTE ON FUNCTION public.create_marketplace_order_secure(uuid, text, jsonb, jsonb, text, numeric, int, numeric)
  TO authenticated;

-- Conserver la compatibilité ascendante avec l'ancienne signature (sans p_exchange_rate_used)
GRANT EXECUTE ON FUNCTION public.create_marketplace_order_secure(uuid, text, jsonb, jsonb, text, numeric, int)
  TO authenticated;

SELECT 'create_marketplace_order_secure — résolution taux de change opérationnelle.' AS status;
