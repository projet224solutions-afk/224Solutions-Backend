-- ─────────────────────────────────────────────────────────────────
-- RPC: admin_change_vendor_currency
--
-- Permet au PDG de changer la devise d'une boutique vendeur.
-- Effets :
--   • Met à jour vendors.shop_currency + seller_country_code
--   • Marque tous les produits actifs needs_currency_review = true
--     (le vendeur doit re-vérifier ses prix dans la nouvelle devise)
--   • Retourne un warning si des escrows actifs existent (commandes en cours
--     qui resteront dans l'ancienne devise — c'est voulu et normal)
-- ─────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_change_vendor_currency(
  p_vendor_id       UUID,
  p_new_currency    VARCHAR(3),
  p_new_country_code VARCHAR(2),
  p_reason          TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_role     TEXT;
  v_old_currency    VARCHAR(3);
  v_active_escrow   INT := 0;
  v_products_flagged INT := 0;
BEGIN
  -- 1. Vérification du rôle appelant
  SELECT role INTO v_caller_role
  FROM profiles
  WHERE id = auth.uid();

  IF v_caller_role IS DISTINCT FROM 'pdg' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Réservé au PDG');
  END IF;

  -- 2. Récupérer la devise actuelle
  SELECT shop_currency INTO v_old_currency
  FROM vendors
  WHERE id = p_vendor_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Vendeur introuvable');
  END IF;

  -- 3. Même devise → no-op
  IF UPPER(v_old_currency) = UPPER(p_new_currency) THEN
    RETURN jsonb_build_object(
      'success', true,
      'changed', false,
      'message', 'La devise est déjà ' || p_new_currency
    );
  END IF;

  -- 4. Compter les escrows actifs (commandes en cours dans l'ancienne devise)
  SELECT COUNT(*) INTO v_active_escrow
  FROM escrow_transactions et
  JOIN orders o ON o.id = et.order_id
  WHERE o.vendor_id = p_vendor_id
    AND et.status IN ('held', 'pending');

  -- 5. Mettre à jour le vendeur
  UPDATE vendors
  SET
    shop_currency       = UPPER(p_new_currency),
    seller_country_code = UPPER(p_new_country_code),
    currency_locked     = true,
    updated_at          = now()
  WHERE id = p_vendor_id;

  -- 6. Flaguer les produits actifs pour révision des prix
  --    On met à jour seller_currency mais PAS original_price_currency car les anciens
  --    prix sont dans l'ancienne devise. Le vendeur doit les corriger manuellement.
  UPDATE products
  SET
    needs_currency_review = true,
    seller_currency       = UPPER(p_new_currency),
    updated_at            = now()
  WHERE vendor_id = p_vendor_id
    AND is_active = true;

  GET DIAGNOSTICS v_products_flagged = ROW_COUNT;

  RETURN jsonb_build_object(
    'success',              true,
    'changed',              true,
    'old_currency',         v_old_currency,
    'new_currency',         UPPER(p_new_currency),
    'new_country_code',     UPPER(p_new_country_code),
    'products_flagged',     v_products_flagged,
    'active_escrow_count',  v_active_escrow,
    'warning', CASE
      WHEN v_active_escrow > 0
      THEN v_active_escrow::TEXT || ' commande(s) en cours restent dans l''ancienne devise (' || v_old_currency || '). C''est normal.'
      ELSE NULL
    END
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_change_vendor_currency(UUID, VARCHAR, VARCHAR, TEXT)
  TO authenticated;
