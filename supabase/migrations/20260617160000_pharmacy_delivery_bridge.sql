-- ============================================================================
-- LIVRAISON PHARMACIE ↔ SYSTÈME LIVREUR MUTUALISÉ (modèle restaurant).
--
-- La table `deliveries` (dispatch livreur + GPS + carte) devient aussi liée aux
-- commandes pharmacie. Une commande pharmacie « livraison » crée AUTOMATIQUEMENT une
-- course (trigger, quel que soit le chemin) ; le livreur la prend dans le système
-- existant ; à la livraison, il est payé 98,5 % des frais (séquestrés chez le PDG),
-- exactement comme pour le restaurant. Le pharmacien peut chiffrer les frais au devis.
-- Idempotent.
-- ============================================================================

-- 0) Frais de livraison chiffrables par le pharmacien au moment du devis.
ALTER TABLE public.prescriptions
  ADD COLUMN IF NOT EXISTS delivery_fee numeric NOT NULL DEFAULT 0;

-- 1) Pont : deliveries.pharmacy_order_id (FK, une seule course par commande).
ALTER TABLE public.deliveries
  ADD COLUMN IF NOT EXISTS pharmacy_order_id uuid REFERENCES public.pharmacy_orders(id) ON DELETE CASCADE;

CREATE UNIQUE INDEX IF NOT EXISTS uniq_deliveries_pharmacy_order
  ON public.deliveries(pharmacy_order_id) WHERE pharmacy_order_id IS NOT NULL;

-- 2) Au moins une référence de commande (e-commerce, restaurant OU pharmacie).
DO $$
BEGIN
  ALTER TABLE public.deliveries DROP CONSTRAINT IF EXISTS deliveries_one_order_ref;
  ALTER TABLE public.deliveries
    ADD CONSTRAINT deliveries_one_order_ref
    CHECK (order_id IS NOT NULL OR restaurant_order_id IS NOT NULL OR pharmacy_order_id IS NOT NULL) NOT VALID;
END $$;

-- 3) Filet de sécurité : créer la course dès qu'une commande pharmacie « livraison » est en
--    préparation (idempotent, best-effort, ne bloque jamais la commande).
CREATE OR REPLACE FUNCTION public.ensure_pharmacy_delivery()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_svc   record;
  v_name  text;
  v_phone text;
BEGIN
  IF NEW.delivery_type <> 'delivery' THEN RETURN NEW; END IF;
  IF NEW.status NOT IN ('preparing', 'ready', 'delivering') THEN RETURN NEW; END IF;
  IF EXISTS (SELECT 1 FROM public.deliveries WHERE pharmacy_order_id = NEW.id) THEN RETURN NEW; END IF;

  SELECT business_name, phone, address, latitude, longitude INTO v_svc
  FROM public.professional_services WHERE id = NEW.pharmacy_id;

  -- Contact client (le livreur DOIT pouvoir joindre).
  IF NEW.client_id IS NOT NULL THEN
    SELECT COALESCE(p.full_name, NULLIF(trim(COALESCE(p.first_name,'') || ' ' || COALESCE(p.last_name,'')), ''), 'Client'),
           p.phone INTO v_name, v_phone
    FROM public.profiles p WHERE p.id = NEW.client_id;
  END IF;

  BEGIN
    INSERT INTO public.deliveries (
      pharmacy_order_id, status, delivery_fee, client_id, package_type,
      vendor_name, customer_name, customer_phone, pickup_address, delivery_address)
    VALUES (
      NEW.id, 'pending', COALESCE(NEW.delivery_fee, 0), NEW.client_id, 'pharmacy',
      COALESCE(v_svc.business_name, 'Pharmacie'), COALESCE(v_name, 'Client'), v_phone,
      jsonb_build_object('name', COALESCE(v_svc.business_name, 'Pharmacie'), 'phone', v_svc.phone,
                         'address', v_svc.address, 'lat', v_svc.latitude, 'lng', v_svc.longitude),
      jsonb_build_object('text', NEW.delivery_address, 'name', v_name, 'phone', v_phone));
  EXCEPTION
    WHEN unique_violation THEN NULL;
    WHEN OTHERS THEN RAISE WARNING 'ensure_pharmacy_delivery %: %', NEW.id, SQLERRM;
  END;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_ensure_pharmacy_delivery ON public.pharmacy_orders;
CREATE TRIGGER trg_ensure_pharmacy_delivery
  AFTER INSERT OR UPDATE OF status ON public.pharmacy_orders
  FOR EACH ROW EXECUTE FUNCTION public.ensure_pharmacy_delivery();

-- 4) Versement livreur à la livraison confirmée (frais client séquestrés chez le PDG → livreur 98,5%).
CREATE OR REPLACE FUNCTION public.pay_pharmacy_delivery(p_delivery_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  d         public.deliveries;
  o         public.pharmacy_orders;
  v_pdg     uuid;
  v_earning numeric;
  v_margin  numeric;
  v_cur     text := 'GNF';
BEGIN
  SELECT * INTO d FROM public.deliveries WHERE id = p_delivery_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'LIVRAISON_INTROUVABLE'; END IF;
  IF d.pharmacy_order_id IS NULL THEN RETURN jsonb_build_object('success', true, 'skipped', 'non_pharmacy'); END IF;
  IF d.driver_id IS NULL OR d.status <> 'delivered' THEN RAISE EXCEPTION 'LIVRAISON_NON_LIVREE'; END IF;
  IF d.driver_paid_at IS NOT NULL THEN RETURN jsonb_build_object('success', true, 'already_paid', true); END IF;

  SELECT * INTO o FROM public.pharmacy_orders WHERE id = d.pharmacy_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'COMMANDE_INTROUVABLE'; END IF;
  IF COALESCE(o.delivery_fee, 0) <= 0 THEN
    UPDATE public.deliveries SET driver_paid_at = now() WHERE id = p_delivery_id;
    RETURN jsonb_build_object('success', true, 'fee', 0);
  END IF;

  v_earning := round(o.delivery_fee * 0.985);
  v_margin  := o.delivery_fee - v_earning;
  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;

  -- Frais payés par le client → séquestrés chez le PDG : on prélève la part livreur.
  IF v_pdg IS NOT NULL THEN
    PERFORM public.wallet_debit_internal(v_pdg, v_earning, 'Reversement livreur pharmacie (frais séquestrés)', 'pharma_deliv_payout:'||p_delivery_id::text);
  END IF;
  PERFORM public.credit_user_wallet_safe(d.driver_id, v_earning, v_cur);

  INSERT INTO public.wallet_transactions (transaction_id, sender_user_id, receiver_user_id, amount, net_amount, currency, transaction_type, status, description, metadata)
  VALUES (generate_transaction_id(), v_pdg, d.driver_id, v_earning, v_earning, v_cur, 'payment', 'completed', 'Gain de livraison pharmacie',
    jsonb_build_object('delivery_id', p_delivery_id, 'pharmacy_order_id', d.pharmacy_order_id, 'kind', 'delivery_earning'));

  UPDATE public.deliveries SET driver_paid_at = now(), driver_earning = v_earning WHERE id = p_delivery_id;
  RETURN jsonb_build_object('success', true, 'driver_earning', v_earning, 'margin', v_margin);
END;
$$;
REVOKE ALL ON FUNCTION public.pay_pharmacy_delivery(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pay_pharmacy_delivery(uuid) TO authenticated, service_role;

-- 5) À la livraison : clore la commande pharmacie + payer le livreur (trigger, tous chemins).
CREATE OR REPLACE FUNCTION public.sync_pharmacy_order_on_delivery()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.pharmacy_order_id IS NOT NULL AND NEW.status = 'delivered' AND (OLD.status IS DISTINCT FROM 'delivered') THEN
    UPDATE public.pharmacy_orders
    SET status = 'delivered', updated_at = now()
    WHERE id = NEW.pharmacy_order_id AND status NOT IN ('delivered', 'collected', 'cancelled');
    BEGIN
      PERFORM public.pay_pharmacy_delivery(NEW.id);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'pay_pharmacy_delivery %: %', NEW.id, SQLERRM;
    END;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_pharmacy_order_on_delivery ON public.deliveries;
CREATE TRIGGER trg_sync_pharmacy_order_on_delivery
  AFTER UPDATE OF status ON public.deliveries
  FOR EACH ROW EXECUTE FUNCTION public.sync_pharmacy_order_on_delivery();

SELECT 'Livraison pharmacie mutualisée : pont deliveries.pharmacy_order_id + frais devis + auto-course + versement livreur (98,5%).' AS status;
