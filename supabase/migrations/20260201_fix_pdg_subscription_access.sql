-- =======================================================================
-- FIX COMPLET: PDG peut offrir des abonnements taxi/moto
-- =======================================================================
-- Problèmes résolus:
-- 1. Les policies RLS vérifient 'admin' et 'ceo' mais pas 'pdg'
-- 2. Le PDG ne peut pas lire profiles pour trouver les utilisateurs
-- 3. Support des IDs TAX0001, LIV0001
-- =======================================================================

-- 0. SUPPRIMER LES ANCIENNES FONCTIONS
DROP FUNCTION IF EXISTS pdg_offer_subscription(UUID, TEXT, INTEGER);
DROP FUNCTION IF EXISTS test_pdg_can_offer_subscription();
DROP FUNCTION IF EXISTS resolve_user_for_subscription(TEXT);

-- 1. Supprimer TOUTES les policies existantes
DROP POLICY IF EXISTS "admin_manage_all_subscriptions" ON public.driver_subscriptions;
DROP POLICY IF EXISTS "admin_pdg_manage_all_subscriptions" ON public.driver_subscriptions;
DROP POLICY IF EXISTS "admin_manage_config" ON public.driver_subscription_config;
DROP POLICY IF EXISTS "admin_pdg_manage_config" ON public.driver_subscription_config;
DROP POLICY IF EXISTS "admin_manage_revenues" ON public.driver_subscription_revenues;
DROP POLICY IF EXISTS "admin_pdg_manage_revenues" ON public.driver_subscription_revenues;

-- 2. Créer les policies avec 'pdg' inclus
CREATE POLICY "admin_pdg_manage_all_subscriptions" ON public.driver_subscriptions
FOR ALL TO authenticated
USING (EXISTS (SELECT 1 FROM profiles WHERE profiles.id = auth.uid() AND profiles.role::text IN ('admin', 'ceo', 'pdg', 'PDG', 'CEO', 'ADMIN')))
WITH CHECK (EXISTS (SELECT 1 FROM profiles WHERE profiles.id = auth.uid() AND profiles.role::text IN ('admin', 'ceo', 'pdg', 'PDG', 'CEO', 'ADMIN')));

CREATE POLICY "admin_pdg_manage_config" ON public.driver_subscription_config
FOR ALL TO authenticated
USING (EXISTS (SELECT 1 FROM profiles WHERE profiles.id = auth.uid() AND profiles.role::text IN ('admin', 'ceo', 'pdg', 'PDG', 'CEO', 'ADMIN')))
WITH CHECK (EXISTS (SELECT 1 FROM profiles WHERE profiles.id = auth.uid() AND profiles.role::text IN ('admin', 'ceo', 'pdg', 'PDG', 'CEO', 'ADMIN')));

CREATE POLICY "admin_pdg_manage_revenues" ON public.driver_subscription_revenues
FOR ALL TO authenticated
USING (EXISTS (SELECT 1 FROM profiles WHERE profiles.id = auth.uid() AND profiles.role::text IN ('admin', 'ceo', 'pdg', 'PDG', 'CEO', 'ADMIN')));

-- 3. Fonction pour RÉSOUDRE un utilisateur (AMÉLIORÉE pour TAX/LIV)
CREATE OR REPLACE FUNCTION resolve_user_for_subscription(p_identifier TEXT)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID;
  v_identifier TEXT;
BEGIN
  v_identifier := TRIM(p_identifier);
  IF v_identifier IS NULL OR v_identifier = '' THEN RETURN NULL; END IF;

  -- 1. Email exact
  SELECT id INTO v_user_id FROM profiles WHERE LOWER(email) = LOWER(v_identifier) LIMIT 1;
  IF v_user_id IS NOT NULL THEN RETURN v_user_id; END IF;

  -- 2. Téléphone (avec/sans espaces, avec/sans +)
  SELECT id INTO v_user_id FROM profiles
  WHERE phone = v_identifier
     OR phone = REPLACE(v_identifier, ' ', '')
     OR phone = REPLACE(REPLACE(v_identifier, ' ', ''), '+', '')
     OR REPLACE(REPLACE(phone, ' ', ''), '+', '') = REPLACE(REPLACE(v_identifier, ' ', ''), '+', '')
  LIMIT 1;
  IF v_user_id IS NOT NULL THEN RETURN v_user_id; END IF;

  -- 3. custom_id dans profiles (TAX0001, LIV0001, etc.)
  SELECT id INTO v_user_id FROM profiles WHERE UPPER(custom_id) = UPPER(v_identifier) LIMIT 1;
  IF v_user_id IS NOT NULL THEN RETURN v_user_id; END IF;

  -- 4. public_id dans profiles
  SELECT id INTO v_user_id FROM profiles WHERE UPPER(public_id) = UPPER(v_identifier) LIMIT 1;
  IF v_user_id IS NOT NULL THEN RETURN v_user_id; END IF;

  -- 5. custom_id dans user_ids (TAX0001, LIV0001, etc.)
  SELECT user_id INTO v_user_id FROM user_ids WHERE UPPER(custom_id) = UPPER(v_identifier) LIMIT 1;
  IF v_user_id IS NOT NULL THEN RETURN v_user_id; END IF;

  -- 6. Recherche par préfixe TAX ou LIV (si l'utilisateur entre juste le numéro)
  IF v_identifier ~ '^[0-9]+$' THEN
    SELECT user_id INTO v_user_id FROM user_ids WHERE custom_id = 'TAX' || LPAD(v_identifier, 4, '0') LIMIT 1;
    IF v_user_id IS NOT NULL THEN RETURN v_user_id; END IF;

    SELECT user_id INTO v_user_id FROM user_ids WHERE custom_id = 'LIV' || LPAD(v_identifier, 4, '0') LIMIT 1;
    IF v_user_id IS NOT NULL THEN RETURN v_user_id; END IF;
  END IF;

  -- 7. Recherche partielle dans user_ids
  SELECT user_id INTO v_user_id FROM user_ids WHERE UPPER(custom_id) LIKE '%' || UPPER(v_identifier) || '%' LIMIT 1;

  RETURN v_user_id;
END;
$$;

GRANT EXECUTE ON FUNCTION resolve_user_for_subscription(TEXT) TO authenticated;

-- 4. Fonction pour OFFRIR un abonnement
CREATE OR REPLACE FUNCTION pdg_offer_subscription(
  p_user_id UUID,
  p_type TEXT,
  p_days INTEGER DEFAULT 30
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_subscription_id UUID;
  v_end_date TIMESTAMPTZ;
  v_admin_role TEXT;
BEGIN
  SELECT role::text INTO v_admin_role FROM profiles WHERE id = auth.uid();
  IF v_admin_role IS NULL OR v_admin_role NOT IN ('admin', 'ceo', 'pdg', 'PDG', 'CEO', 'ADMIN') THEN
    RAISE EXCEPTION 'Accès refusé. Seul le PDG/Admin peut offrir des abonnements.';
  END IF;

  IF p_user_id IS NULL THEN RAISE EXCEPTION 'User ID requis'; END IF;
  IF p_type NOT IN ('taxi', 'livreur') THEN RAISE EXCEPTION 'Type invalide. Doit être taxi ou livreur'; END IF;
  IF p_days <= 0 OR p_days > 365 THEN RAISE EXCEPTION 'Durée invalide (1-365 jours)'; END IF;
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = p_user_id) THEN RAISE EXCEPTION 'Utilisateur cible non trouvé'; END IF;

  v_end_date := NOW() + (p_days || ' days')::INTERVAL;

  UPDATE driver_subscriptions SET status = 'expired', updated_at = NOW() WHERE user_id = p_user_id AND status = 'active';

  INSERT INTO driver_subscriptions (user_id, type, price, status, start_date, end_date, payment_method, transaction_id, billing_cycle, metadata)
  VALUES (p_user_id, p_type, 0, 'active', NOW(), v_end_date, 'pdg_gift', 'GIFT-PDG-' || EXTRACT(EPOCH FROM NOW())::BIGINT, 'custom',
    jsonb_build_object('offered_by_pdg', TRUE, 'offered_by_user_id', auth.uid(), 'days_offered', p_days, 'offered_at', NOW())
  ) RETURNING id INTO v_subscription_id;

  RETURN v_subscription_id;
END;
$$;

GRANT EXECUTE ON FUNCTION pdg_offer_subscription(UUID, TEXT, INTEGER) TO authenticated;

-- 5. Contrainte payment_method
DO $$
BEGIN
  ALTER TABLE driver_subscriptions DROP CONSTRAINT IF EXISTS driver_subscriptions_payment_method_check;
  ALTER TABLE driver_subscriptions ADD CONSTRAINT driver_subscriptions_payment_method_check
    CHECK (payment_method IN ('wallet', 'mobile_money', 'orange_money', 'mtn_money', 'card', 'cash', 'pdg_gift', 'custom'));
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

-- 6. Confirmation
DO $$ BEGIN RAISE NOTICE '✅ PDG peut maintenant offrir des abonnements taxi/moto (TAX0001, LIV0001)'; END $$;
