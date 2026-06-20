-- ============================================================================
-- CAISSE PHARMACIE HORS LIGNE — vente comptoir ATOMIQUE & IDEMPOTENTE.
--
-- Le pharmacien doit pouvoir encaisser une vente au comptoir SANS internet (parapharmacie,
-- vente libre, délivrance contrôlée en personne — le pharmacien EST l'autorité de validation
-- présente). La vente est stockée localement (IndexedDB) puis rejouée à la reconnexion via
-- cette RPC : insert pharmacy_orders + décrément stock dans UNE transaction.
--
-- Réglée EN PERSONNE (espèces/MoMo/carte) → AUCUN mouvement wallet, AUCUNE commission (comme
-- la caisse restaurant). Idempotence : idempotency_key STABLE généré hors ligne
-- (« PHARMA-OFF-… ») + contrainte UNIQUE existante → un rejeu n'encaisse pas deux fois.
-- Idempotent (migration).
-- ============================================================================

-- Distinguer les ventes comptoir des commandes en ligne (analytics / Kanban).
ALTER TABLE public.pharmacy_orders
  ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'client';

CREATE OR REPLACE FUNCTION public.create_pharmacy_pos_offline_order(
  p_service_id      uuid,
  p_idempotency_key text,
  p_sale            jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner    uuid;
  v_order_id uuid;
  v_items    jsonb := COALESCE(p_sale->'items', '[]'::jsonb);
  it         jsonb;
  v_mid      uuid;
  v_qty      int;
  v_total    numeric;
BEGIN
  IF p_service_id IS NULL OR p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) < 6 THEN
    RAISE EXCEPTION 'PARAMS_INVALIDES';
  END IF;

  -- Autorisation : seul le propriétaire de la pharmacie peut encaisser sur sa caisse.
  SELECT user_id INTO v_owner FROM public.professional_services WHERE id = p_service_id;
  IF v_owner IS NULL THEN RAISE EXCEPTION 'SERVICE_INTROUVABLE'; END IF;
  IF auth.uid() IS NULL OR auth.uid() <> v_owner THEN RAISE EXCEPTION 'NON_AUTORISE'; END IF;

  v_total := GREATEST(0, COALESCE((p_sale->>'total')::numeric, 0));

  -- Insertion idempotente (idempotency_key UNIQUE) : un rejeu ne réinsère pas.
  INSERT INTO public.pharmacy_orders (
    pharmacy_id, client_id, prescription_id, amount, commission, delivery_fee,
    medications, delivery_type, delivery_address, status, payment_status,
    idempotency_key, source, created_at)
  VALUES (
    p_service_id, NULL, NULL, v_total, 0, 0,
    v_items, 'pickup', NULL, 'collected', 'paid',
    p_idempotency_key, 'pos', COALESCE((p_sale->>'created_at')::timestamptz, now()))
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING id INTO v_order_id;

  -- Déjà présente (rejeu) → succès idempotent, sans re-décrémenter le stock.
  IF v_order_id IS NULL THEN
    SELECT id INTO v_order_id FROM public.pharmacy_orders WHERE idempotency_key = p_idempotency_key LIMIT 1;
    RETURN jsonb_build_object('status', 'duplicate', 'order_id', v_order_id);
  END IF;

  -- Première insertion → décrément stock BEST-EFFORT (même transaction). Vente déjà encaissée
  -- en personne : on n'ÉCHOUE JAMAIS sur stock insuffisant (clamp à 0).
  FOR it IN SELECT * FROM jsonb_array_elements(v_items) LOOP
    v_mid := NULLIF(it->>'medication_id', '')::uuid;
    v_qty := GREATEST(1, COALESCE((it->>'quantity')::int, 1));
    IF v_mid IS NULL THEN CONTINUE; END IF;
    UPDATE public.pharmacy_medications
    SET stock = GREATEST(0, stock - v_qty), updated_at = now()
    WHERE id = v_mid AND pharmacy_id = p_service_id;
  END LOOP;

  RETURN jsonb_build_object('status', 'created', 'order_id', v_order_id);
END;
$$;

REVOKE ALL ON FUNCTION public.create_pharmacy_pos_offline_order(uuid, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_pharmacy_pos_offline_order(uuid, text, jsonb) TO authenticated, service_role;

SELECT 'Caisse pharmacie hors ligne : colonne source + RPC atomique create_pharmacy_pos_offline_order.' AS status;
