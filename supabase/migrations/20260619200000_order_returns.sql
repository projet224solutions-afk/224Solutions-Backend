-- ============================================================================
-- 📦↩️ DEMANDES DE RETOUR (return requests) — politique de remboursement pro.
--
-- Flux : client (commande livrée, fenêtre 14j) demande un retour (motif) →
-- vendeur APPROUVE/REJETTE → client renvoie → vendeur marque REÇU → remboursement
-- ATOMIQUE (escrow → acheteur) + RESTOCK des articles retournés. Plus structuré que
-- le litige générique (états, motif, remboursement déclenché à la réception du colis).
-- Toutes les mutations passent par le backend (service_role) ; RLS = lecture seule scopée.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.order_returns (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id      uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  customer_id   uuid REFERENCES public.customers(id) ON DELETE SET NULL,
  vendor_id     uuid NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  reason        text NOT NULL CHECK (reason IN ('defective','not_as_described','wrong_item','no_longer_needed','other')),
  comment       text,
  items         jsonb NOT NULL DEFAULT '[]',   -- [{product_id, quantity, unit_price, name}]
  refund_amount numeric NOT NULL DEFAULT 0,
  status        text NOT NULL DEFAULT 'requested'
                CHECK (status IN ('requested','approved','rejected','received','refunded','cancelled')),
  vendor_response text,
  requested_at  timestamptz NOT NULL DEFAULT now(),
  approved_at   timestamptz,
  received_at   timestamptz,
  refunded_at   timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_order_returns_order  ON public.order_returns(order_id);
CREATE INDEX IF NOT EXISTS idx_order_returns_vendor ON public.order_returns(vendor_id, status);
CREATE INDEX IF NOT EXISTS idx_order_returns_customer ON public.order_returns(customer_id);
-- Une seule demande active par commande (évite les doublons / double-remboursement).
CREATE UNIQUE INDEX IF NOT EXISTS uq_order_returns_active
  ON public.order_returns(order_id) WHERE status IN ('requested','approved','received');

ALTER TABLE public.order_returns ENABLE ROW LEVEL SECURITY;

-- Lecture : le client (propriétaire) et le vendeur (boutique). Écriture = backend (service_role).
DROP POLICY IF EXISTS order_returns_client_select ON public.order_returns;
CREATE POLICY order_returns_client_select ON public.order_returns
  FOR SELECT TO authenticated
  USING (customer_id IN (SELECT id FROM public.customers WHERE user_id = auth.uid()));

DROP POLICY IF EXISTS order_returns_vendor_select ON public.order_returns;
CREATE POLICY order_returns_vendor_select ON public.order_returns
  FOR SELECT TO authenticated
  USING (vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid()));

-- ── RPC : remboursement + restock à la réception (atomique, idempotent) ──
CREATE OR REPLACE FUNCTION public.process_order_return_refund(p_return_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_ret   public.order_returns%ROWTYPE;
  v_item  jsonb;
  v_pid   uuid;
  v_qty   numeric;
  v_done  int := 0;
BEGIN
  SELECT * INTO v_ret FROM public.order_returns WHERE id = p_return_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RETURN_NOT_FOUND'; END IF;

  IF v_ret.status = 'refunded' THEN
    RETURN jsonb_build_object('success', true, 'already_refunded', true);
  END IF;
  IF v_ret.status <> 'received' THEN
    RAISE EXCEPTION 'NOT_RECEIVED'; -- on ne rembourse qu'après réception du colis
  END IF;

  -- 1) Remboursement de l'acheteur (recrédit wallet + escrow 'refunded'), tant que dans la fenêtre.
  PERFORM public.refund_order_escrow(v_ret.order_id);

  -- 2) Restock des articles retournés.
  FOR v_item IN SELECT * FROM jsonb_array_elements(COALESCE(v_ret.items, '[]'::jsonb)) LOOP
    v_pid := NULLIF(v_item->>'product_id', '')::uuid;
    v_qty := COALESCE((v_item->>'quantity')::numeric, 0);
    IF v_pid IS NOT NULL AND v_qty > 0 THEN
      UPDATE public.products
         SET stock_quantity = COALESCE(stock_quantity, 0) + v_qty, updated_at = now()
       WHERE id = v_pid;
      v_done := v_done + 1;
    END IF;
  END LOOP;

  -- 3) Statuts.
  UPDATE public.order_returns
     SET status = 'refunded', refunded_at = now(), updated_at = now()
   WHERE id = p_return_id;
  UPDATE public.orders SET payment_status = 'refunded', updated_at = now() WHERE id = v_ret.order_id;

  RETURN jsonb_build_object('success', true, 'restocked', v_done, 'refund_amount', v_ret.refund_amount);
END;
$$;

REVOKE ALL ON FUNCTION public.process_order_return_refund(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.process_order_return_refund(uuid) TO service_role;

SELECT 'Module retours créé : table order_returns + RLS + RPC process_order_return_refund (remboursement+restock à réception).' AS status;
