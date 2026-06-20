-- ============================================================================
-- 🤝 PROGRAMME D'AFFILIATION VENDEUR (type Amazon Associates) — Phase 1 : fondation.
--
-- Modèle (validé) : PAR PRODUIT, fenêtre d'attribution 30 j, ouvert à tout utilisateur
-- (anti-auto-affiliation). L'affilié partage un lien produit ; un clic est attribué
-- (last-click, 30 j) ; à l'achat une commission `pending` est créée ; à la libération
-- escrow elle est CONFIRMÉE = créditée au wallet de l'affilié et DÉBITÉE du vendeur
-- (le vendeur paie ses affiliés). Annulée si remboursement/retour.
--
-- Cette migration = SCHÉMA + RPC atomiques (confirm/cancel). Les hooks (clic, conversion,
-- libération escrow) seront câblés côté backend (Phase 2).
-- ============================================================================

-- 1) Activation par produit + taux.
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS affiliate_enabled boolean NOT NULL DEFAULT false;
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS affiliate_commission_rate numeric NOT NULL DEFAULT 0
  CHECK (affiliate_commission_rate >= 0 AND affiliate_commission_rate <= 90);

-- 2) Clics d'affiliation (attribution last-click, fenêtre 30 j). Clé = (affilié, produit, acheteur).
CREATE TABLE IF NOT EXISTS public.affiliate_clicks (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id        uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  affiliate_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  buyer_user_id     uuid REFERENCES auth.users(id) ON DELETE CASCADE,  -- acheteur (si connecté au clic)
  clicked_at        timestamptz NOT NULL DEFAULT now(),
  expires_at        timestamptz NOT NULL DEFAULT (now() + interval '30 days'),
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_aff_clicks_attr ON public.affiliate_clicks(buyer_user_id, product_id, expires_at DESC);
CREATE INDEX IF NOT EXISTS idx_aff_clicks_affiliate ON public.affiliate_clicks(affiliate_user_id, clicked_at DESC);

-- 3) Commissions d'affiliation (conversions). 1 par (commande, produit, affilié).
CREATE TABLE IF NOT EXISTS public.affiliate_commissions (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id          uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  product_id        uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  affiliate_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  vendor_id         uuid NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  sale_amount       numeric NOT NULL CHECK (sale_amount >= 0),
  commission_rate   numeric NOT NULL,
  commission_amount numeric NOT NULL CHECK (commission_amount >= 0),
  currency          text NOT NULL DEFAULT 'GNF',
  status            text NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','confirmed','cancelled')),
  created_at        timestamptz NOT NULL DEFAULT now(),
  confirmed_at      timestamptz,
  cancelled_at      timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_aff_commission ON public.affiliate_commissions(order_id, product_id, affiliate_user_id);
CREATE INDEX IF NOT EXISTS idx_aff_commission_affiliate ON public.affiliate_commissions(affiliate_user_id, status);
CREATE INDEX IF NOT EXISTS idx_aff_commission_vendor ON public.affiliate_commissions(vendor_id, status);

ALTER TABLE public.affiliate_clicks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.affiliate_commissions ENABLE ROW LEVEL SECURITY;

-- Lecture : l'affilié voit ses clics/commissions ; le vendeur voit les commissions de sa boutique.
DROP POLICY IF EXISTS aff_clicks_select ON public.affiliate_clicks;
CREATE POLICY aff_clicks_select ON public.affiliate_clicks FOR SELECT TO authenticated
  USING (affiliate_user_id = auth.uid());

DROP POLICY IF EXISTS aff_comm_affiliate_select ON public.affiliate_commissions;
CREATE POLICY aff_comm_affiliate_select ON public.affiliate_commissions FOR SELECT TO authenticated
  USING (affiliate_user_id = auth.uid());

DROP POLICY IF EXISTS aff_comm_vendor_select ON public.affiliate_commissions;
CREATE POLICY aff_comm_vendor_select ON public.affiliate_commissions FOR SELECT TO authenticated
  USING (vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid()));
-- (Écritures = backend service_role uniquement.)

-- 4) RPC : confirmer + payer les commissions d'une commande (à la libération escrow).
--    Atomique + idempotent : crédite l'affilié (credit_user_wallet_safe) et DÉBITE le vendeur
--    (wallet_debit_internal) du montant de commission. Ne re-paie jamais une commission déjà confirmée.
CREATE OR REPLACE FUNCTION public.confirm_affiliate_commissions(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_row     public.affiliate_commissions%ROWTYPE;
  v_vendor_user uuid;
  v_count   int := 0;
BEGIN
  FOR v_row IN
    SELECT * FROM public.affiliate_commissions
    WHERE order_id = p_order_id AND status = 'pending'
    FOR UPDATE
  LOOP
    IF v_row.commission_amount > 0 THEN
      SELECT user_id INTO v_vendor_user FROM public.vendors WHERE id = v_row.vendor_id;
      -- Débit vendeur (le vendeur finance la commission de son affilié) puis crédit affilié.
      IF v_vendor_user IS NOT NULL THEN
        PERFORM public.wallet_debit_internal(v_vendor_user, v_row.commission_amount,
          'Commission affiliation (vente #' || left(p_order_id::text, 8) || ')',
          'aff_comm_debit:' || v_row.id::text);
      END IF;
      PERFORM public.credit_user_wallet_safe(v_row.affiliate_user_id, v_row.commission_amount,
        NULL, 'affiliate_commission', v_row.id::text);
    END IF;
    UPDATE public.affiliate_commissions
       SET status = 'confirmed', confirmed_at = now() WHERE id = v_row.id;
    v_count := v_count + 1;
  END LOOP;
  RETURN jsonb_build_object('success', true, 'confirmed', v_count);
END;
$$;

-- 5) RPC : annuler les commissions d'une commande (remboursement/retour). Pending → cancelled.
CREATE OR REPLACE FUNCTION public.cancel_affiliate_commissions(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_count int;
BEGIN
  UPDATE public.affiliate_commissions
     SET status = 'cancelled', cancelled_at = now()
   WHERE order_id = p_order_id AND status = 'pending';
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN jsonb_build_object('success', true, 'cancelled', v_count);
END;
$$;

REVOKE ALL ON FUNCTION public.confirm_affiliate_commissions(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cancel_affiliate_commissions(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.confirm_affiliate_commissions(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.cancel_affiliate_commissions(uuid) TO service_role;

SELECT 'Affiliation vendeur (Phase 1) : products.affiliate_*, affiliate_clicks, affiliate_commissions + RPC confirm/cancel atomiques.' AS status;
