-- ================================================================
-- FIX create_marketplace_order_secure — 2026-05-17
--
-- Problèmes corrigés :
--   1. La fonction peut avoir été supprimée (CASCADE) lors de précédentes
--      migrations qui droppaient create_order_core — on la recrée.
--
--   2. La fonction ne passait pas p_buyer_wallet_currency à create_order_core,
--      ce qui causait un échec Phase 0 pour les achats cross-devise :
--      create_order_core cherchait le wallet de l'acheteur dans la DEVISE
--      DU VENDEUR au lieu de la devise réelle du wallet de l'acheteur.
--
-- Fix :
--   - CREATE OR REPLACE (idempotent — crée si absent, remplace si présent)
--   - Résolution automatique de la devise du wallet acheteur depuis la DB
--   - Passage de p_buyer_wallet_currency à create_order_core
-- ================================================================

CREATE OR REPLACE FUNCTION public.create_marketplace_order_secure(
  p_vendor_id           uuid,
  p_payment_method      text,
  p_items               jsonb   DEFAULT '[]'::jsonb,
  p_shipping_address    jsonb   DEFAULT '{}'::jsonb,
  p_currency            text    DEFAULT 'GNF',
  p_wallet_debit_amount numeric DEFAULT 0,
  p_auto_release_days   int     DEFAULT 7
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_buyer_user_id   uuid := auth.uid();
  v_customer_id     uuid;
  v_vendor_user_id  uuid;
  v_order_number    text;
  v_buyer_wallet_cur text := NULL;
BEGIN
  -- Sécurité : auth.uid() est forcé — impossible depuis le frontend de passer un autre user
  IF v_buyer_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Authentification requise');
  END IF;

  -- Récupérer ou créer le customer lié à cet utilisateur
  SELECT id INTO v_customer_id
  FROM public.customers
  WHERE user_id = v_buyer_user_id
  LIMIT 1;

  IF v_customer_id IS NULL THEN
    INSERT INTO public.customers (user_id)
    VALUES (v_buyer_user_id)
    RETURNING id INTO v_customer_id;
  END IF;

  -- Récupérer le user_id du vendeur (le vrai propriétaire de la boutique)
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

  -- Résoudre la devise du wallet de l'acheteur (pour paiement wallet cross-devise)
  -- Sans ce fix, create_order_core cherche le wallet de l'acheteur dans la devise
  -- du VENDEUR (p_currency) → introuvable si acheteur et vendeur ont des devises différentes.
  IF p_payment_method = 'wallet' AND p_wallet_debit_amount > 0 THEN
    SELECT currency INTO v_buyer_wallet_cur
    FROM public.wallets
    WHERE user_id = v_buyer_user_id
    LIMIT 1;
    -- Si aucun wallet trouvé → NULL → create_order_core utilisera p_currency par défaut
  END IF;

  -- Numéro de commande unique
  v_order_number := 'ORD-' || upper(replace(gen_random_uuid()::text, '-', ''));
  v_order_number := left(v_order_number, 20);

  -- Déléguer à create_order_core (qui gère stock, escrow, wallet atomiquement)
  -- p_buyer_wallet_currency permet de débiter le bon wallet (devise acheteur)
  -- même en cas de paiement cross-devise (ex: acheteur GNF, vendeur XOF)
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
    p_buyer_wallet_currency  := v_buyer_wallet_cur
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

-- Accorder l'exécution aux utilisateurs authentifiés
GRANT EXECUTE ON FUNCTION public.create_marketplace_order_secure(uuid, text, jsonb, jsonb, text, numeric, int)
  TO authenticated;

SELECT 'create_marketplace_order_secure — recréée avec fix devise wallet cross-currency.' AS status;
