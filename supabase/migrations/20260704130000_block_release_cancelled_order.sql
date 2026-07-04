-- 🛑 ESCROW : INTERDIRE la libération au vendeur quand la commande est ANNULÉE
-- ─────────────────────────────────────────────────────────────────────────────
-- CONSTAT (audit 2026-07-04) : ORD-MR2LSPR5-BET4 annulée le 02/07 07:38, escrow
-- LIBÉRÉ AU VENDEUR le 02/07 22:00 par le job auto-release de l'ancien code prod
-- (l'acheteur a payé, la commande est annulée, le vendeur a quand même été payé).
-- Le job Node actuel filtre déjà les commandes annulées (et les REMBOURSE désormais),
-- mais ce trigger est le VERROU CÔTÉ BASE : il bloque TOUT écrivain — y compris un
-- backend obsolète encore déployé — qui tenterait de passer un escrow à 'released'
-- alors que sa commande est 'cancelled'. Le remboursement (status 'refunded') reste
-- autorisé : c'est la seule sortie légitime d'un escrow de commande annulée.

CREATE OR REPLACE FUNCTION public.block_release_on_cancelled_order()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status = 'released'
     AND COALESCE(OLD.status, '') IS DISTINCT FROM 'released'
     AND NEW.order_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.orders o WHERE o.id = NEW.order_id AND o.status = 'cancelled')
  THEN
    RAISE EXCEPTION 'ESCROW_ORDER_CANCELLED: liberation refusee — la commande % est annulee ; utiliser refund_order_escrow', NEW.order_id
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_block_release_cancelled_order ON public.escrow_transactions;
CREATE TRIGGER trg_block_release_cancelled_order
  BEFORE INSERT OR UPDATE OF status ON public.escrow_transactions
  FOR EACH ROW
  EXECUTE FUNCTION public.block_release_on_cancelled_order();

SELECT 'Verrou actif : un escrow de commande annulée ne peut plus être libéré au vendeur (remboursement seul autorisé).' AS status;
