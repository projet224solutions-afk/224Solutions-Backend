-- ============================================================================
-- LIVRAISON PHARMACIE — créer la course quand la commande est PRÊTE (pas à 'preparing').
--
-- AJUSTEMENT métier : contrairement au restaurant (le livreur est dispatché pendant la
-- cuisson), la préparation pharmaceutique est manuelle (vérification, rassemblement des
-- médicaments, parfois attente de stock). Dispatcher un livreur dès le paiement ('preparing')
-- pourrait le faire arriver AVANT que la commande soit prête. On crée donc la course
-- uniquement quand le pharmacien marque la commande 'ready' (ou directement 'delivering').
-- Seule la condition de statut change ; tout le reste (idempotence, contact, frais) est inchangé.
-- Idempotent.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.ensure_pharmacy_delivery()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_svc   record;
  v_name  text;
  v_phone text;
BEGIN
  IF NEW.delivery_type <> 'delivery' THEN RETURN NEW; END IF;
  -- La course n'est créée que lorsque la commande est PRÊTE à partir (pas en 'preparing').
  IF NEW.status NOT IN ('ready', 'delivering') THEN RETURN NEW; END IF;
  IF EXISTS (SELECT 1 FROM public.deliveries WHERE pharmacy_order_id = NEW.id) THEN RETURN NEW; END IF;

  SELECT business_name, phone, address, latitude, longitude INTO v_svc
  FROM public.professional_services WHERE id = NEW.pharmacy_id;

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

SELECT 'Livraison pharmacie : course créée à ''ready'' (médicaments préparés), plus à ''preparing''.' AS status;
