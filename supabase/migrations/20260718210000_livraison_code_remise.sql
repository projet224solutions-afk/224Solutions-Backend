-- ============================================================
-- 🔐 CODE DE REMISE CLIENT (preuve de livraison renforcée)
-- Chaque livraison reçoit un code 4 chiffres, montré au CLIENT dans son app
-- (notification au départ du colis). Le livreur doit le saisir à la remise :
-- complete_delivery vérifie le code EN BASE avant de passer 'delivered'.
-- Photo + signature restent ; le code désamorce les litiges « pas reçu ».
-- ============================================================

-- 1) Colonnes
ALTER TABLE public.deliveries ADD COLUMN IF NOT EXISTS confirm_code text;
ALTER TABLE public.deliveries ADD COLUMN IF NOT EXISTS confirm_code_verified_at timestamptz;

-- 2) Génération à l'INSERT (étend le trigger tracking_code existant)
CREATE OR REPLACE FUNCTION public.set_delivery_tracking_code()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_code text;
  v_tries int := 0;
  v_bytes bytea;
  v_alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; -- 31 chars, sans 0/O/1/I/L
BEGIN
  IF NEW.tracking_code IS NULL THEN
    LOOP
      SELECT 'CL' || string_agg(substr(v_alphabet, (get_byte(gen_random_bytes(1), 0) % 31) + 1, 1), '')
        INTO v_code FROM generate_series(1, 8);
      EXIT WHEN NOT EXISTS (SELECT 1 FROM public.deliveries WHERE tracking_code = v_code);
      v_tries := v_tries + 1;
      IF v_tries > 5 THEN
        v_code := 'CL' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));
        EXIT;
      END IF;
    END LOOP;
    NEW.tracking_code := v_code;
  END IF;

  IF NEW.confirm_code IS NULL THEN
    v_bytes := gen_random_bytes(2);
    NEW.confirm_code := lpad((((get_byte(v_bytes, 0) << 8) + get_byte(v_bytes, 1)) % 10000)::text, 4, '0');
  END IF;

  RETURN NEW;
END $$;

REVOKE ALL ON FUNCTION public.set_delivery_tracking_code() FROM PUBLIC, anon, authenticated;

-- 3) Backfill des livraisons non terminées
UPDATE public.deliveries
   SET confirm_code = lpad((floor(random() * 10000))::text, 4, '0')
 WHERE confirm_code IS NULL
   AND status NOT IN ('delivered', 'cancelled');

-- 4) complete_delivery : signature étendue (p_confirm_code) — l'ancienne signature
--    est SUPPRIMÉE (sinon surcharge ambiguë côté PostgREST).
DROP FUNCTION IF EXISTS public.complete_delivery(uuid, uuid, text, text);

CREATE OR REPLACE FUNCTION public.complete_delivery(
  p_delivery_id uuid,
  p_driver_id uuid,
  p_proof text DEFAULT NULL,
  p_signature text DEFAULT NULL,
  p_confirm_code text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE v_row public.deliveries%ROWTYPE; v_earning numeric; v_is_cash boolean; v_already boolean;
BEGIN
  SELECT * INTO v_row FROM public.deliveries WHERE id = p_delivery_id FOR UPDATE;
  IF NOT FOUND OR v_row.driver_id <> p_driver_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'not_owner');
  END IF;
  v_earning := public._delivery_earning(v_row.driver_earning, v_row.delivery_fee);
  v_is_cash := public._delivery_is_cash(v_row.payment_method);
  v_already := (v_row.status = 'delivered');

  -- 🔐 Code de remise client : vérifié EN BASE (le front n'est jamais l'arbitre).
  IF NOT v_already AND v_row.confirm_code IS NOT NULL THEN
    IF p_confirm_code IS NULL OR trim(p_confirm_code) = '' THEN
      RETURN jsonb_build_object('success', false, 'error', 'confirm_code_required');
    END IF;
    IF trim(p_confirm_code) <> v_row.confirm_code THEN
      RETURN jsonb_build_object('success', false, 'error', 'confirm_code_invalid');
    END IF;
  END IF;

  IF NOT v_already THEN
    UPDATE public.deliveries
       SET status = 'delivered', completed_at = now(), driver_earning = v_earning,
           proof_photo_url = COALESCE(p_proof, proof_photo_url),
           client_signature = COALESCE(p_signature, client_signature),
           confirm_code_verified_at = CASE WHEN confirm_code IS NOT NULL THEN now() ELSE confirm_code_verified_at END,
           driver_payment_method = CASE WHEN v_is_cash THEN lower(coalesce(v_row.payment_method, 'cash')) ELSE driver_payment_method END
     WHERE id = p_delivery_id;
    UPDATE public.drivers
       SET earnings_total = coalesce(earnings_total, 0) + v_earning,
           total_deliveries = coalesce(total_deliveries, 0) + 1, status = 'online'
     WHERE user_id = p_driver_id;
  END IF;

  RETURN jsonb_build_object('success', true, 'driver_earning', v_earning, 'is_cash', v_is_cash,
    'payment_method', lower(coalesce(v_row.payment_method, 'prepaid')),
    'already_completed', v_already, 'already_paid', (v_row.driver_payment_method IS NOT NULL));
END $$;

REVOKE ALL ON FUNCTION public.complete_delivery(uuid, uuid, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.complete_delivery(uuid, uuid, text, text, text) TO authenticated, service_role;
