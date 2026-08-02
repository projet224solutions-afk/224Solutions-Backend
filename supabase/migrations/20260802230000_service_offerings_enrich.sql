-- ═══════════════════════════════════════════════════════════════════════════════
-- PRESTATIONS IT — enrichissement (alignement à la spec) : price_type, category_label,
-- duration_label, sort_order + bornes strictes + max 30/service + RPC from/quote + notification prestataire.
-- ═══════════════════════════════════════════════════════════════════════════════
-- Complète 20260802210000 (table) + 20260802220000 (RPC), déjà appliqués. Aucune ligne existante (0) → sûr.

-- 1) Colonnes attendues par la spec/hook enrichi.
ALTER TABLE public.service_offerings
  ADD COLUMN IF NOT EXISTS category_label text,
  ADD COLUMN IF NOT EXISTS price_type     text NOT NULL DEFAULT 'fixed' CHECK (price_type IN ('fixed','from','quote')),
  ADD COLUMN IF NOT EXISTS duration_label text,
  ADD COLUMN IF NOT EXISTS sort_order     int NOT NULL DEFAULT 0;

-- 2) Bornes strictes (add-only : se COMPOSENT avec les CHECK existants → net = la plus stricte).
ALTER TABLE public.service_offerings
  ADD CONSTRAINT service_offerings_title_max80    CHECK (char_length(btrim(title)) <= 80),
  ADD CONSTRAINT service_offerings_desc_max500    CHECK (description IS NULL OR char_length(description) <= 500),
  ADD CONSTRAINT service_offerings_catlabel_max60 CHECK (category_label IS NULL OR char_length(category_label) <= 60),
  ADD CONSTRAINT service_offerings_durlabel_max40 CHECK (duration_label IS NULL OR char_length(duration_label) <= 40);

CREATE INDEX IF NOT EXISTS idx_service_offerings_sort ON public.service_offerings (professional_service_id, sort_order);

-- 3) Max 30 prestations par service (BEFORE INSERT).
CREATE OR REPLACE FUNCTION public.service_offerings_max_per_service()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (SELECT count(*) FROM public.service_offerings WHERE professional_service_id = NEW.professional_service_id) >= 30 THEN
    RAISE EXCEPTION 'TOO_MANY_OFFERINGS: 30 prestations maximum par service' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS trg_service_offerings_max ON public.service_offerings;
CREATE TRIGGER trg_service_offerings_max BEFORE INSERT ON public.service_offerings
  FOR EACH ROW EXECUTE FUNCTION public.service_offerings_max_per_service();

-- 4) RPC create_quote_from_offering — gère price_type + notifie le prestataire.
--    fixed → devis 'sent' au prix serveur (payable). from/quote → devis 'draft' (le prestataire FIXE/confirme
--    le montant avant envoi ; Bloc 0 autorise l'édition en draft et empêche d'encaisser un montant non
--    confirmé). AUCUN mouvement d'argent (pay_quote_atomic / release_quote_atomic inchangés).
CREATE OR REPLACE FUNCTION public.create_quote_from_offering(p_offering_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_client uuid := auth.uid();
  v_off    record;
  v_qid    uuid;
  v_status text;
  v_amount numeric;
BEGIN
  IF v_client IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_AUTHENTICATED');
  END IF;

  SELECT o.id, o.professional_service_id, o.title, o.description, o.base_price, o.escrow,
         COALESCE(o.price_type, 'fixed') AS price_type, ps.user_id AS owner_id
  INTO v_off
  FROM public.service_offerings o
  JOIN public.professional_services ps ON ps.id = o.professional_service_id
  WHERE o.id = p_offering_id AND o.is_active = true;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'OFFERING_NOT_FOUND');
  END IF;
  IF v_off.owner_id IS NOT DISTINCT FROM v_client THEN
    RETURN jsonb_build_object('success', false, 'error', 'OWN_OFFERING');
  END IF;

  IF v_off.price_type = 'fixed' THEN
    IF COALESCE(v_off.base_price, 0) <= 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'BAD_PRICE');
    END IF;
    v_status := 'sent';
    v_amount := v_off.base_price;
  ELSE
    v_status := 'draft';   -- le prestataire fixe/confirme le montant avant envoi
    v_amount := CASE WHEN v_off.price_type = 'from' THEN COALESCE(v_off.base_price, 0) ELSE 0 END;
  END IF;

  INSERT INTO public.service_quotes (
    professional_service_id, client_user_id, title, description,
    line_items, total_amount, escrow, escrow_status, status)
  VALUES (
    v_off.professional_service_id, v_client, v_off.title, v_off.description,
    jsonb_build_array(jsonb_build_object('label', v_off.title, 'qty', 1, 'unit_price', v_amount)),
    v_amount, COALESCE(v_off.escrow, true), 'none', v_status)
  RETURNING id INTO v_qid;

  -- Notifier le prestataire (best-effort, ne fait jamais échouer la commande).
  BEGIN
    INSERT INTO public.notifications (user_id, title, message, type, metadata)
    VALUES (
      v_off.owner_id,
      'Nouvelle commande de prestation',
      v_off.title || CASE WHEN v_status = 'draft' THEN ' — un client a commandé (à chiffrer).' ELSE ' — un client a commandé.' END,
      'service_quote_order',
      jsonb_build_object('quote_id', v_qid, 'offering_id', v_off.id, 'price_type', v_off.price_type));
  EXCEPTION WHEN others THEN NULL;
  END;

  RETURN jsonb_build_object('success', true, 'quote_id', v_qid, 'total_amount', v_amount,
                            'status', v_status, 'needs_pricing', v_status = 'draft');
END;
$$;

REVOKE ALL ON FUNCTION public.create_quote_from_offering(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_quote_from_offering(uuid) TO authenticated, service_role;
