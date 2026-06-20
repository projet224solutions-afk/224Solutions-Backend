-- 1. Add cancellable column to orders
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS cancellable BOOLEAN DEFAULT true;

-- 2. Add seller_confirmed_at and auto_release_date to escrow_transactions
ALTER TABLE public.escrow_transactions ADD COLUMN IF NOT EXISTS seller_confirmed_at TIMESTAMPTZ;
ALTER TABLE public.escrow_transactions ADD COLUMN IF NOT EXISTS auto_release_date TIMESTAMPTZ;
ALTER TABLE public.escrow_transactions ADD COLUMN IF NOT EXISTS dispute_status TEXT;

-- 3. Create escrow_disputes table
CREATE TABLE IF NOT EXISTS public.escrow_disputes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  escrow_id UUID NOT NULL REFERENCES public.escrow_transactions(id) ON DELETE CASCADE,
  initiator_user_id UUID NOT NULL,
  initiator_role TEXT NOT NULL CHECK (initiator_role IN ('buyer', 'seller')),
  reason TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'under_review', 'resolved')),
  resolution TEXT CHECK (resolution IN ('release_to_seller', 'refund_to_buyer')),
  resolution_notes TEXT,
  resolved_by UUID,
  created_at TIMESTAMPTZ DEFAULT now(),
  resolved_at TIMESTAMPTZ,
  evidence_urls TEXT[],
  metadata JSONB
);

-- 4. Enable RLS on escrow_disputes
ALTER TABLE public.escrow_disputes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own disputes" ON public.escrow_disputes FOR SELECT USING (initiator_user_id = auth.uid());
CREATE POLICY "Service role full access disputes" ON public.escrow_disputes FOR ALL USING (auth.jwt()->>'role' = 'service_role');

GRANT SELECT, INSERT ON public.escrow_disputes TO authenticated;

-- 5. Index for auto-release
CREATE INDEX IF NOT EXISTS idx_escrow_auto_release ON public.escrow_transactions (auto_release_date) WHERE status IN ('pending', 'held') AND dispute_status IS NULL;

-- 6. Updated auto_release_escrows function
CREATE OR REPLACE FUNCTION public.auto_release_escrows()
RETURNS TABLE(escrow_id UUID, success BOOLEAN, message TEXT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = 'public'
AS $function$
DECLARE
  v_escrow RECORD;
  v_commission_percent NUMERIC;
BEGIN
  SELECT COALESCE(
    (SELECT setting_value::NUMERIC FROM public.system_settings WHERE setting_key = 'escrow_commission_percent'), 2.5
  ) INTO v_commission_percent;
  
  FOR v_escrow IN
    SELECT et.id, et.order_id, et.receiver_id, et.payer_id, et.amount
    FROM public.escrow_transactions et
    WHERE et.status IN ('pending', 'held')
      AND et.dispute_status IS NULL
      AND (
        (et.auto_release_date IS NOT NULL AND et.auto_release_date <= now())
        OR (et.auto_release_enabled = true AND et.available_to_release_at <= now())
      )
    ORDER BY COALESCE(et.auto_release_date, et.available_to_release_at) ASC
    LIMIT 100
  LOOP
    BEGIN
      PERFORM release_escrow(v_escrow.id, v_commission_percent, NULL);
      PERFORM log_escrow_action(v_escrow.id, 'auto_released', NULL, 'Auto-released after 7-day deadline');
      
      IF v_escrow.order_id IS NOT NULL THEN
        UPDATE public.orders SET status = 'delivered', payment_status = 'paid', updated_at = now()
        WHERE id = v_escrow.order_id AND status != 'delivered';
      END IF;

      INSERT INTO public.notifications (user_id, title, message, type, metadata) VALUES 
        (v_escrow.receiver_id, 'Fonds libérés automatiquement', 'Les fonds ont été libérés après le délai de 7 jours.', 'escrow', jsonb_build_object('escrow_id', v_escrow.id, 'action', 'auto_release')),
        (v_escrow.payer_id, 'Transaction finalisée', 'Votre commande a été finalisée après le délai de 7 jours.', 'escrow', jsonb_build_object('escrow_id', v_escrow.id, 'action', 'auto_release'));
      
      escrow_id := v_escrow.id;
      success := true;
      message := 'Auto-released after 7-day deadline';
      RETURN NEXT;
    EXCEPTION WHEN OTHERS THEN
      escrow_id := v_escrow.id;
      success := false;
      message := SQLERRM;
      RETURN NEXT;
    END;
  END LOOP;
END;
$function$;