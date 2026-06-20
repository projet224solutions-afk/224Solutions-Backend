-- ================================================================
-- FONCTION SÉCURISÉE POUR LA CRÉATION DE COMMANDES MARKETPLACE
-- Bypasse le backend Node.js (et son middleware idempotency cassé)
-- Utilise auth.uid() → impossible d'usurper l'identité d'un autre acheteur
-- ================================================================

-- 1. Colonnes manquantes (idempotentes)
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS currency TEXT DEFAULT 'GNF';

ALTER TABLE public.order_items
  ADD COLUMN IF NOT EXISTS product_name TEXT;

ALTER TABLE public.escrow_transactions
  ADD COLUMN IF NOT EXISTS buyer_id          UUID,
  ADD COLUMN IF NOT EXISTS seller_id         UUID,
  ADD COLUMN IF NOT EXISTS payer_id          UUID,
  ADD COLUMN IF NOT EXISTS receiver_id       UUID,
  ADD COLUMN IF NOT EXISTS payment_method    TEXT,
  ADD COLUMN IF NOT EXISTS commission_amount NUMERIC DEFAULT 0,
  ADD COLUMN IF NOT EXISTS auto_release_at   TIMESTAMPTZ;

UPDATE public.escrow_transactions
SET auto_release_at = auto_release_date
WHERE auto_release_at IS NULL AND auto_release_date IS NOT NULL;

-- 2. Supprimer l'ancienne version si elle existe
DROP FUNCTION IF EXISTS public.create_marketplace_order_secure(uuid, text, jsonb, jsonb, text, numeric, int);

-- 3. Créer la fonction sécurisée
CREATE FUNCTION public.create_marketplace_order_secure(
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
  v_buyer_user_id  uuid := auth.uid();
  v_customer_id    uuid;
  v_vendor_user_id uuid;
  v_order_number   text;
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

  -- Numéro de commande unique
  v_order_number := 'ORD-' || upper(replace(gen_random_uuid()::text, '-', ''));
  v_order_number := left(v_order_number, 20);

  -- Déléguer à create_order_core (qui gère stock, escrow, wallet atomiquement)
  RETURN public.create_order_core(
    p_order_number        := v_order_number,
    p_customer_id         := v_customer_id,
    p_vendor_id           := p_vendor_id,
    p_vendor_user_id      := v_vendor_user_id,
    p_payment_method      := p_payment_method,
    p_shipping_address    := p_shipping_address,
    p_currency            := p_currency,
    p_items               := p_items,
    p_auto_release_days   := p_auto_release_days,
    p_buyer_user_id       := v_buyer_user_id,
    p_wallet_debit_amount := p_wallet_debit_amount
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

-- 4. Accorder l'exécution aux utilisateurs authentifiés
GRANT EXECUTE ON FUNCTION public.create_marketplace_order_secure(uuid, text, jsonb, jsonb, text, numeric, int)
  TO authenticated;

-- 5. Vérification
SELECT 'create_marketplace_order_secure créée — utilisateurs authentifiés peuvent créer des commandes sans passer par le backend.' AS status;
