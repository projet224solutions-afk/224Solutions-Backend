-- ============================================================================
-- MIGRATION: SYSTÈME COMPLET DE GESTION DES ACTIONNAIRES
-- Date: 2026-05-24
-- Intégration dans l'application 224Solutions existante
-- ============================================================================

-- ============================================================================
-- 1. AJOUTER LE RÔLE 'actionnaire' AUX PROFILS EXISTANTS
-- ============================================================================
-- NOTE: ALTER TYPE user_role ADD VALUE 'actionnaire' appliqué séparément
-- (ALTER TYPE ADD VALUE ne peut pas être dans une transaction).

-- ============================================================================
-- 2. AJOUTER offered_by_ceo AUX TABLES D'ABONNEMENTS EXISTANTES
-- ============================================================================

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name='driver_subscriptions' AND column_name='offered_by_ceo'
  ) THEN
    ALTER TABLE public.driver_subscriptions ADD COLUMN offered_by_ceo BOOLEAN DEFAULT false;
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name='driver_subscriptions' AND column_name='payment_status'
  ) THEN
    ALTER TABLE public.driver_subscriptions ADD COLUMN payment_status TEXT DEFAULT 'paid'
      CHECK (payment_status IN ('pending','paid','failed','refunded'));
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name='service_subscriptions' AND column_name='offered_by_ceo'
  ) THEN
    ALTER TABLE public.service_subscriptions ADD COLUMN offered_by_ceo BOOLEAN DEFAULT false;
  END IF;
END $$;

-- ============================================================================
-- 3. TABLE shareholders
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.shareholders (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name     TEXT NOT NULL,
  email         TEXT NOT NULL,
  phone         TEXT,
  status        TEXT NOT NULL DEFAULT 'active'
                CHECK (status IN ('active','suspended','archived')),
  created_by    UUID REFERENCES auth.users(id),
  internal_notes TEXT,
  created_at    TIMESTAMPTZ DEFAULT now(),
  updated_at    TIMESTAMPTZ DEFAULT now(),
  UNIQUE(user_id)
);

CREATE INDEX IF NOT EXISTS idx_shareholders_user_id ON public.shareholders(user_id);
CREATE INDEX IF NOT EXISTS idx_shareholders_status  ON public.shareholders(status);

-- ============================================================================
-- 4. TABLE shareholder_assignments
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.shareholder_assignments (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shareholder_id UUID NOT NULL REFERENCES public.shareholders(id) ON DELETE CASCADE,
  category       TEXT NOT NULL
                 CHECK (category IN ('seller','service','taxi','delivery_driver','digital_vendor')),
  action_scope   TEXT NOT NULL
                 CHECK (action_scope IN ('country','global')),
  country        TEXT,   -- ISO-2 code, NULL si global
  percentage     NUMERIC(5,2) NOT NULL
                 CHECK (percentage > 0 AND percentage <= 100),
  status         TEXT NOT NULL DEFAULT 'active'
                 CHECK (status IN ('active','suspended','archived')),
  created_at     TIMESTAMPTZ DEFAULT now(),
  updated_at     TIMESTAMPTZ DEFAULT now(),
  -- Unicité : un actionnaire ne peut avoir qu'un seul assignment actif par combo category+scope+country
  UNIQUE(shareholder_id, category, action_scope, country)
);

CREATE INDEX IF NOT EXISTS idx_sh_assign_shareholder ON public.shareholder_assignments(shareholder_id);
CREATE INDEX IF NOT EXISTS idx_sh_assign_category    ON public.shareholder_assignments(category, action_scope);
CREATE INDEX IF NOT EXISTS idx_sh_assign_country     ON public.shareholder_assignments(country);

-- Contrainte: country obligatoire si scope=country, null si scope=global
DO $$ BEGIN
  ALTER TABLE public.shareholder_assignments
    ADD CONSTRAINT sh_assign_country_scope CHECK (
      (action_scope = 'country' AND country IS NOT NULL) OR
      (action_scope = 'global'  AND country IS NULL)
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ============================================================================
-- 5. TABLE shareholder_revenues
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.shareholder_revenues (
  id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shareholder_id          UUID NOT NULL REFERENCES public.shareholders(id) ON DELETE CASCADE,
  assignment_id           UUID NOT NULL REFERENCES public.shareholder_assignments(id),
  category                TEXT NOT NULL
                          CHECK (category IN ('seller','service','taxi','delivery_driver','digital_vendor')),
  period_start            DATE NOT NULL,
  period_end              DATE NOT NULL,
  action_scope            TEXT NOT NULL CHECK (action_scope IN ('country','global')),
  country                 TEXT,
  paid_subscriptions_count INTEGER DEFAULT 0,
  free_subscriptions_count INTEGER DEFAULT 0,
  total_paid_revenue      NUMERIC(15,2) DEFAULT 0,
  percentage              NUMERIC(5,2) NOT NULL,
  shareholder_amount      NUMERIC(15,2) DEFAULT 0,
  currency                TEXT DEFAULT 'GNF',
  payment_status          TEXT NOT NULL DEFAULT 'pending'
                          CHECK (payment_status IN ('pending','approved','sent_to_wallet','withdrawn','cancelled')),
  notes                   TEXT,
  created_at              TIMESTAMPTZ DEFAULT now(),
  updated_at              TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sh_rev_shareholder ON public.shareholder_revenues(shareholder_id);
CREATE INDEX IF NOT EXISTS idx_sh_rev_period      ON public.shareholder_revenues(period_start, period_end);
CREATE INDEX IF NOT EXISTS idx_sh_rev_status      ON public.shareholder_revenues(payment_status);

-- Empêcher le double calcul pour la même période (un seul revenu par assignment + période)
ALTER TABLE public.shareholder_revenues
  DROP CONSTRAINT IF EXISTS sh_rev_unique_period;

ALTER TABLE public.shareholder_revenues
  ADD CONSTRAINT sh_rev_unique_period
  UNIQUE (assignment_id, period_start, period_end);

-- ============================================================================
-- 6. TABLE shareholder_payments
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.shareholder_payments (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shareholder_id        UUID NOT NULL REFERENCES public.shareholders(id) ON DELETE CASCADE,
  revenue_id            UUID NOT NULL REFERENCES public.shareholder_revenues(id),
  wallet_transaction_id UUID,  -- référence à wallet_transactions après envoi
  amount                NUMERIC(15,2) NOT NULL,
  currency              TEXT DEFAULT 'GNF',
  status                TEXT NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending','approved','sent_to_wallet','withdrawn','cancelled')),
  approved_by           UUID REFERENCES auth.users(id),
  approved_at           TIMESTAMPTZ,
  sent_to_wallet_at     TIMESTAMPTZ,
  created_at            TIMESTAMPTZ DEFAULT now(),
  updated_at            TIMESTAMPTZ DEFAULT now(),
  UNIQUE(revenue_id)  -- un seul paiement par revenue
);

CREATE INDEX IF NOT EXISTS idx_sh_pay_shareholder ON public.shareholder_payments(shareholder_id);
CREATE INDEX IF NOT EXISTS idx_sh_pay_status      ON public.shareholder_payments(status);

-- ============================================================================
-- 7. TABLE shareholder_documents
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.shareholder_documents (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title          TEXT NOT NULL,
  document_type  TEXT NOT NULL
                 CHECK (document_type IN (
                   'shareholder_contract','payment_receipt','monthly_report',
                   'financial_report','meeting_minutes','participation_certificate',
                   'tax_document','other'
                 )),
  file_url       TEXT,
  content        TEXT,  -- pour les rapports générés dynamiquement
  visibility     TEXT NOT NULL DEFAULT 'all'
                 CHECK (visibility IN (
                   'all','specific_shareholder','country','global',
                   'category','category_country'
                 )),
  shareholder_id UUID REFERENCES public.shareholders(id),  -- si visibility=specific_shareholder
  category       TEXT,   -- si visibility=category ou category_country
  country        TEXT,   -- si visibility=country ou category_country
  uploaded_by    UUID REFERENCES auth.users(id),
  is_public      BOOLEAN DEFAULT false,
  created_at     TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sh_docs_visibility     ON public.shareholder_documents(visibility);
CREATE INDEX IF NOT EXISTS idx_sh_docs_shareholder_id ON public.shareholder_documents(shareholder_id);
CREATE INDEX IF NOT EXISTS idx_sh_docs_category       ON public.shareholder_documents(category);

-- ============================================================================
-- 8. TABLE shareholder_votes
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.shareholder_votes (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title          TEXT NOT NULL,
  description    TEXT,
  start_date     TIMESTAMPTZ NOT NULL,
  end_date       TIMESTAMPTZ NOT NULL,
  vote_type      TEXT NOT NULL DEFAULT 'simple'
                 CHECK (vote_type IN ('simple','weighted')),
  target_type    TEXT NOT NULL DEFAULT 'all'
                 CHECK (target_type IN (
                   'all','country','global','category',
                   'category_country','specific_shareholder'
                 )),
  category       TEXT,
  country        TEXT,
  shareholder_id UUID REFERENCES public.shareholders(id),
  status         TEXT NOT NULL DEFAULT 'open'
                 CHECK (status IN ('draft','open','closed','cancelled')),
  created_by     UUID REFERENCES auth.users(id),
  created_at     TIMESTAMPTZ DEFAULT now(),
  updated_at     TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.shareholder_vote_responses (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vote_id        UUID NOT NULL REFERENCES public.shareholder_votes(id) ON DELETE CASCADE,
  shareholder_id UUID NOT NULL REFERENCES public.shareholders(id),
  choice         TEXT NOT NULL CHECK (choice IN ('yes','no','abstain')),
  vote_weight    NUMERIC(5,2) DEFAULT 1,
  created_at     TIMESTAMPTZ DEFAULT now(),
  UNIQUE(vote_id, shareholder_id)
);

-- ============================================================================
-- 9. TABLE shareholder_audit_logs
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.shareholder_audit_logs (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id    UUID REFERENCES auth.users(id),
  action      TEXT NOT NULL,  -- ex: 'create_shareholder', 'update_percentage', 'approve_payment'
  entity_type TEXT NOT NULL,  -- ex: 'shareholder', 'assignment', 'payment', 'revenue'
  entity_id   UUID,
  old_value   JSONB,
  new_value   JSONB,
  ip_address  TEXT,
  created_at  TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sh_audit_entity    ON public.shareholder_audit_logs(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_sh_audit_actor     ON public.shareholder_audit_logs(actor_id);
CREATE INDEX IF NOT EXISTS idx_sh_audit_created   ON public.shareholder_audit_logs(created_at DESC);

-- ============================================================================
-- 10. TABLE shareholder_notifications (réutilise notifications existantes)
--     On utilise la table notifications existante et on ajoute juste un type
-- ============================================================================

-- Pas de nouvelle table — on utilise la table notifications existante
-- avec type='shareholder_revenue', 'shareholder_payment', etc.

-- ============================================================================
-- 11. TABLE monthly_reports
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.shareholder_monthly_reports (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shareholder_id UUID NOT NULL REFERENCES public.shareholders(id) ON DELETE CASCADE,
  period_start   DATE NOT NULL,
  period_end     DATE NOT NULL,
  file_url       TEXT,
  report_data    JSONB,  -- données du rapport en cache
  generated_by   UUID REFERENCES auth.users(id),
  generated_at   TIMESTAMPTZ DEFAULT now()
);

-- ============================================================================
-- 12. FONCTION: VALIDER LES POURCENTAGES (empêche le dépassement de 100%)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.validate_shareholder_percentage(
  p_category        TEXT,
  p_scope           TEXT,
  p_new_percentage  NUMERIC,
  p_country         TEXT DEFAULT NULL,
  p_exclude_id      UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_current_total NUMERIC := 0;
  v_remaining     NUMERIC;
BEGIN
  -- Calculer le total actuel pour cette combinaison category + scope + country
  SELECT COALESCE(SUM(sa.percentage), 0)
  INTO v_current_total
  FROM public.shareholder_assignments sa
  WHERE sa.category = p_category
    AND sa.action_scope = p_scope
    AND (
      (p_scope = 'global' AND sa.country IS NULL) OR
      (p_scope = 'country' AND sa.country = p_country)
    )
    AND sa.status = 'active'
    AND (p_exclude_id IS NULL OR sa.id != p_exclude_id);

  v_remaining := 100 - v_current_total;

  IF p_new_percentage > v_remaining THEN
    RETURN jsonb_build_object(
      'valid',     false,
      'current',   v_current_total,
      'remaining', v_remaining,
      'requested', p_new_percentage,
      'message',   'Le pourcentage demandé dépasse la limite disponible (' ||
                   v_remaining::TEXT || '% restant)'
    );
  END IF;

  RETURN jsonb_build_object(
    'valid',     true,
    'current',   v_current_total,
    'remaining', v_remaining - p_new_percentage,
    'requested', p_new_percentage
  );
END;
$$;

-- ============================================================================
-- 13. FONCTION: OBTENIR LE POURCENTAGE RESTANT
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_remaining_percentage(
  p_category TEXT,
  p_scope    TEXT,
  p_country  TEXT DEFAULT NULL
)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_total NUMERIC := 0;
BEGIN
  SELECT COALESCE(SUM(sa.percentage), 0)
  INTO v_total
  FROM public.shareholder_assignments sa
  WHERE sa.category = p_category
    AND sa.action_scope = p_scope
    AND (
      (p_scope = 'global' AND sa.country IS NULL) OR
      (p_scope = 'country' AND sa.country = p_country)
    )
    AND sa.status = 'active';

  RETURN GREATEST(0, 100 - v_total);
END;
$$;

-- ============================================================================
-- 14. FONCTION: CALCULER LES REVENUS D'UN ACTIONNAIRE
-- ============================================================================

CREATE OR REPLACE FUNCTION public.calculate_shareholder_revenue(
  p_assignment_id UUID,
  p_period_start  DATE,
  p_period_end    DATE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_assignment    RECORD;
  v_paid_count    INTEGER := 0;
  v_free_count    INTEGER := 0;
  v_total_revenue NUMERIC := 0;
  v_sh_amount     NUMERIC := 0;
  v_currency      TEXT    := 'GNF';
BEGIN
  -- Récupérer l'assignment
  SELECT sa.*, s.user_id AS shareholder_user_id
  INTO v_assignment
  FROM public.shareholder_assignments sa
  JOIN public.shareholders s ON s.id = sa.shareholder_id
  WHERE sa.id = p_assignment_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'Assignment introuvable');
  END IF;

  -- Calcul selon la catégorie
  IF v_assignment.category IN ('taxi', 'delivery_driver') THEN
    -- Source: driver_subscriptions
    DECLARE
      v_driver_type TEXT := CASE WHEN v_assignment.category = 'taxi' THEN 'taxi' ELSE 'livreur' END;
    BEGIN
      -- Abonnements PAYANTS (actifs ou expirés — le paiement a bien eu lieu)
      SELECT COUNT(*), COALESCE(SUM(ds.price), 0)
      INTO v_paid_count, v_total_revenue
      FROM public.driver_subscriptions ds
      JOIN public.profiles p ON p.id = ds.user_id
      WHERE ds.type = v_driver_type
        AND ds.status IN ('active', 'expired')
        AND COALESCE(ds.offered_by_ceo, false) = false
        AND COALESCE(ds.payment_status, 'paid') = 'paid'
        AND ds.start_date::date >= p_period_start
        AND ds.start_date::date <= p_period_end
        AND (
          v_assignment.action_scope = 'global' OR
          (v_assignment.action_scope = 'country' AND
           COALESCE(p.country, p.detected_country) = v_assignment.country)
        );

      -- Abonnements OFFERTS (gratuits)
      SELECT COUNT(*)
      INTO v_free_count
      FROM public.driver_subscriptions ds
      JOIN public.profiles p ON p.id = ds.user_id
      WHERE ds.type = v_driver_type
        AND ds.status IN ('active', 'expired')
        AND COALESCE(ds.offered_by_ceo, false) = true
        AND ds.start_date::date >= p_period_start
        AND ds.start_date::date <= p_period_end
        AND (
          v_assignment.action_scope = 'global' OR
          (v_assignment.action_scope = 'country' AND
           COALESCE(p.country, p.detected_country) = v_assignment.country)
        );
    END;

  ELSIF v_assignment.category = 'service' THEN
    -- Source: service_subscriptions
    -- Abonnements services PAYANTS (actifs, expirés ou past_due — paiement encaissé)
    SELECT COUNT(*), COALESCE(SUM(ss.price_paid_gnf), 0)
    INTO v_paid_count, v_total_revenue
    FROM public.service_subscriptions ss
    JOIN public.professional_services ps ON ps.id = ss.professional_service_id
    JOIN public.profiles p ON p.id = ps.user_id
    WHERE ss.status IN ('active', 'expired', 'past_due')
      AND COALESCE(ss.offered_by_ceo, false) = false
      AND ss.price_paid_gnf > 0
      AND ss.started_at::date >= p_period_start
      AND ss.started_at::date <= p_period_end
      AND (
        v_assignment.action_scope = 'global' OR
        (v_assignment.action_scope = 'country' AND
         COALESCE(p.country, p.detected_country) = v_assignment.country)
      );

    -- Abonnements services OFFERTS (gratuits)
    SELECT COUNT(*)
    INTO v_free_count
    FROM public.service_subscriptions ss
    JOIN public.professional_services ps ON ps.id = ss.professional_service_id
    JOIN public.profiles p ON p.id = ps.user_id
    WHERE ss.status IN ('active', 'expired', 'past_due')
      AND COALESCE(ss.offered_by_ceo, false) = true
      AND ss.started_at::date >= p_period_start
      AND ss.started_at::date <= p_period_end
      AND (
        v_assignment.action_scope = 'global' OR
        (v_assignment.action_scope = 'country' AND
         COALESCE(p.country, p.detected_country) = v_assignment.country)
      );

  ELSIF v_assignment.category = 'seller' THEN
    -- Source: vendor_subscriptions (via plans table, user_role='vendeur')
    -- Abonnements vendeurs PAYANTS (actifs ou expirés — paiement encaissé)
    SELECT COUNT(*), COALESCE(SUM(vs.amount_paid), 0)
    INTO v_paid_count, v_total_revenue
    FROM public.vendor_subscriptions vs
    JOIN public.profiles p ON p.id = vs.user_id
    WHERE vs.status IN ('active', 'expired')
      AND COALESCE(vs.offered_by_ceo, false) = false
      AND vs.amount_paid > 0
      AND vs.created_at::date >= p_period_start
      AND vs.created_at::date <= p_period_end
      AND (
        v_assignment.action_scope = 'global' OR
        (v_assignment.action_scope = 'country' AND
         COALESCE(p.country, p.detected_country) = v_assignment.country)
      );

    -- Abonnements vendeurs OFFERTS (gratuits)
    SELECT COUNT(*)
    INTO v_free_count
    FROM public.vendor_subscriptions vs
    JOIN public.profiles p ON p.id = vs.user_id
    WHERE vs.status IN ('active', 'expired')
      AND COALESCE(vs.offered_by_ceo, false) = true
      AND vs.created_at::date >= p_period_start
      AND vs.created_at::date <= p_period_end
      AND (
        v_assignment.action_scope = 'global' OR
        (v_assignment.action_scope = 'country' AND
         COALESCE(p.country, p.detected_country) = v_assignment.country)
      );

  ELSIF v_assignment.category = 'digital_vendor' THEN
    DECLARE
      -- Devise attendue: locale pour portée pays, GNF pour global
      v_dpp_currency TEXT := CASE
        WHEN v_assignment.action_scope = 'country' AND v_assignment.country IS NOT NULL
        THEN get_currency_for_country(v_assignment.country)
        ELSE 'GNF'
      END;
    BEGIN
      -- Propager la devise vers le résultat final
      v_currency := v_dpp_currency;

      -- Achats payants filtrés sur la devise attendue
      SELECT COUNT(*), COALESCE(SUM(dpp.amount), 0)
      INTO v_paid_count, v_total_revenue
      FROM public.digital_product_purchases dpp
      JOIN public.profiles p ON p.id = dpp.merchant_id
      WHERE dpp.payment_status = 'completed'
        AND dpp.amount > 0
        AND (
          dpp.currency = v_dpp_currency
          OR (dpp.currency IS NULL AND v_dpp_currency = 'GNF')
        )
        AND dpp.created_at::date >= p_period_start
        AND dpp.created_at::date <= p_period_end
        AND (
          v_assignment.action_scope = 'global' OR
          (v_assignment.action_scope = 'country' AND
           COALESCE(p.country, p.detected_country) = v_assignment.country)
        );

      -- Achats gratuits (amount = 0)
      SELECT COUNT(*)
      INTO v_free_count
      FROM public.digital_product_purchases dpp
      JOIN public.profiles p ON p.id = dpp.merchant_id
      WHERE dpp.payment_status = 'completed'
        AND dpp.amount = 0
        AND dpp.created_at::date >= p_period_start
        AND dpp.created_at::date <= p_period_end
        AND (
          v_assignment.action_scope = 'global' OR
          (v_assignment.action_scope = 'country' AND
           COALESCE(p.country, p.detected_country) = v_assignment.country)
        );
    END;
  END IF;

  -- Calculer la part de l'actionnaire
  v_sh_amount := v_total_revenue * (v_assignment.percentage / 100);

  RETURN jsonb_build_object(
    'assignment_id',             p_assignment_id,
    'shareholder_id',            v_assignment.shareholder_id,
    'category',                  v_assignment.category,
    'action_scope',              v_assignment.action_scope,
    'country',                   v_assignment.country,
    'paid_subscriptions_count',  v_paid_count,
    'free_subscriptions_count',  v_free_count,
    'total_paid_revenue',        v_total_revenue,
    'percentage',                v_assignment.percentage,
    'shareholder_amount',        v_sh_amount,
    'currency',                  v_currency,
    'period_start',              p_period_start,
    'period_end',                p_period_end
  );
END;
$$;

-- ============================================================================
-- 15. FONCTION: CRÉER UN ACTIONNAIRE (PDG uniquement)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.create_shareholder(
  p_full_name        TEXT,
  p_email            TEXT,
  p_phone            TEXT,
  p_category         TEXT,
  p_scope            TEXT,
  p_country          TEXT,
  p_percentage       NUMERIC,
  p_temp_password    TEXT,
  p_internal_notes   TEXT DEFAULT NULL,
  p_created_by       UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_validation   JSONB;
  v_user_id      UUID;
  v_sh_id        UUID;
  v_assign_id    UUID;
BEGIN
  -- 1. Valider le pourcentage
  v_validation := public.validate_shareholder_percentage(
    p_category, p_scope, p_percentage, p_country
  );

  IF NOT (v_validation->>'valid')::boolean THEN
    RETURN jsonb_build_object('success', false, 'error', v_validation->>'message');
  END IF;

  -- 2. Créer le compte auth (via admin API - géré côté application)
  -- Cette fonction crée uniquement les enregistrements DB côté actionnaire
  -- L'utilisateur doit être créé d'abord via supabase.auth.admin.createUser()

  -- 3. Vérifier que l'utilisateur existe
  SELECT id INTO v_user_id FROM auth.users WHERE email = p_email LIMIT 1;
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Utilisateur non trouvé. Créez le compte auth d''abord.');
  END IF;

  -- 4. Créer la fiche actionnaire
  INSERT INTO public.shareholders (user_id, full_name, email, phone, status, created_by, internal_notes)
  VALUES (v_user_id, p_full_name, p_email, p_phone, 'active', p_created_by, p_internal_notes)
  RETURNING id INTO v_sh_id;

  -- 5. Créer l'assignment
  INSERT INTO public.shareholder_assignments (
    shareholder_id, category, action_scope, country, percentage, status
  ) VALUES (
    v_sh_id, p_category, p_scope,
    CASE WHEN p_scope = 'global' THEN NULL ELSE p_country END,
    p_percentage, 'active'
  )
  RETURNING id INTO v_assign_id;

  -- 6. Audit log
  INSERT INTO public.shareholder_audit_logs (actor_id, action, entity_type, entity_id, new_value)
  VALUES (
    p_created_by, 'create_shareholder', 'shareholder', v_sh_id,
    jsonb_build_object(
      'full_name', p_full_name, 'email', p_email,
      'category', p_category, 'scope', p_scope,
      'country', p_country, 'percentage', p_percentage
    )
  );

  RETURN jsonb_build_object(
    'success',        true,
    'shareholder_id', v_sh_id,
    'assignment_id',  v_assign_id,
    'user_id',        v_user_id
  );
END;
$$;

-- ============================================================================
-- 16. FONCTION: ENVOYER UN PAIEMENT AU WALLET EXISTANT
-- ============================================================================

CREATE OR REPLACE FUNCTION public.send_shareholder_payment_to_wallet(
  p_payment_id UUID,
  p_actor_id   UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_payment          RECORD;
  v_shareholder      RECORD;
  v_wallet_id        UUID;
  v_wallet_currency  TEXT;
  v_payment_currency TEXT;
  v_credited_amount  NUMERIC;
  v_fx_rate          NUMERIC;
  v_tx_id            UUID;
BEGIN
  -- Récupérer le paiement + devise du revenue associé
  SELECT sp.*, sr.currency
  INTO v_payment
  FROM public.shareholder_payments sp
  JOIN public.shareholder_revenues sr ON sr.id = sp.revenue_id
  WHERE sp.id = p_payment_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Paiement introuvable');
  END IF;

  IF v_payment.status = 'sent_to_wallet' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Déjà envoyé au wallet');
  END IF;

  IF v_payment.status != 'approved' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Le paiement doit être approuvé avant envoi');
  END IF;

  -- Récupérer l'actionnaire
  SELECT s.*
  INTO v_shareholder
  FROM public.shareholders s
  WHERE s.id = v_payment.shareholder_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Actionnaire introuvable');
  END IF;

  -- Récupérer le wallet et sa devise
  SELECT id, COALESCE(currency::TEXT, 'GNF')
  INTO v_wallet_id, v_wallet_currency
  FROM public.wallets
  WHERE user_id = v_shareholder.user_id
  LIMIT 1;

  IF v_wallet_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Wallet actionnaire introuvable');
  END IF;

  v_payment_currency := COALESCE(v_payment.currency, 'GNF');
  v_credited_amount  := v_payment.amount;

  -- Conversion FX si le wallet n'est pas dans la même devise que le paiement
  IF v_wallet_currency != v_payment_currency THEN
    -- Chercher taux direct (ex: GNF → XOF)
    SELECT rate_internal
    INTO v_fx_rate
    FROM public.exchange_rates
    WHERE from_currency = v_payment_currency
      AND to_currency   = v_wallet_currency
      AND is_active     = true
    ORDER BY created_at DESC
    LIMIT 1;

    -- Si pas de taux direct, essayer la voie inverse (1 / rate)
    IF v_fx_rate IS NULL THEN
      SELECT 1.0 / NULLIF(rate_internal, 0)
      INTO v_fx_rate
      FROM public.exchange_rates
      WHERE from_currency = v_wallet_currency
        AND to_currency   = v_payment_currency
        AND is_active     = true
      ORDER BY created_at DESC
      LIMIT 1;
    END IF;

    IF v_fx_rate IS NULL THEN
      RETURN jsonb_build_object(
        'success', false,
        'error',   'Taux de change introuvable: ' || v_payment_currency
                   || ' → ' || v_wallet_currency
                   || '. Veuillez mettre à jour les taux de change.'
      );
    END IF;

    v_credited_amount := ROUND(v_payment.amount * v_fx_rate, 2);
  END IF;

  -- Créditer le wallet dans SA devise (montant converti si nécessaire)
  INSERT INTO public.wallet_transactions (
    wallet_id, type, amount, currency, status,
    description, source, source_id, created_at
  ) VALUES (
    v_wallet_id, 'credit', v_credited_amount,
    v_wallet_currency, 'completed',
    'Revenus actionnaire - ' || v_payment.shareholder_id::TEXT,
    'shareholder_revenue', v_payment.revenue_id,
    now()
  )
  RETURNING id INTO v_tx_id;

  -- Mettre à jour le solde wallet dans sa propre devise
  UPDATE public.wallets
  SET balance    = balance + v_credited_amount,
      updated_at = now()
  WHERE id = v_wallet_id;

  -- Mettre à jour le statut du paiement
  UPDATE public.shareholder_payments
  SET status                = 'sent_to_wallet',
      wallet_transaction_id = v_tx_id,
      sent_to_wallet_at     = now(),
      updated_at            = now()
  WHERE id = p_payment_id;

  -- Mettre à jour le statut du revenu
  UPDATE public.shareholder_revenues
  SET payment_status = 'sent_to_wallet', updated_at = now()
  WHERE id = v_payment.revenue_id;

  -- Audit log avec détails de conversion FX
  INSERT INTO public.shareholder_audit_logs (
    actor_id, action, entity_type, entity_id, new_value
  ) VALUES (
    p_actor_id, 'send_payment_to_wallet', 'payment', p_payment_id,
    jsonb_build_object(
      'original_amount',  v_payment.amount,
      'payment_currency', v_payment_currency,
      'credited_amount',  v_credited_amount,
      'wallet_currency',  v_wallet_currency,
      'fx_rate',          v_fx_rate,
      'wallet_tx_id',     v_tx_id,
      'shareholder_id',   v_payment.shareholder_id
    )
  );

  -- Notification à l'actionnaire (avec info de conversion si applicable)
  INSERT INTO public.notifications (user_id, title, message, type, read)
  VALUES (
    v_shareholder.user_id,
    'Paiement reçu',
    'Un paiement de ' || v_credited_amount::TEXT || ' ' || v_wallet_currency
    || CASE WHEN v_wallet_currency != v_payment_currency
       THEN ' (converti depuis ' || v_payment.amount::TEXT || ' ' || v_payment_currency || ')'
       ELSE ''
    END
    || ' a été crédité sur votre wallet.',
    'shareholder_payment',
    false
  );

  RETURN jsonb_build_object(
    'success',            true,
    'wallet_transaction', v_tx_id,
    'original_amount',    v_payment.amount,
    'payment_currency',   v_payment_currency,
    'credited_amount',    v_credited_amount,
    'wallet_currency',    v_wallet_currency
  );
END;
$$;

-- ============================================================================
-- 17. FONCTION: DASHBOARD ACTIONNAIRE (données temps réel)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_shareholder_dashboard(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_sh      RECORD;
  v_assign  RECORD;
  v_result  JSONB;
BEGIN
  -- Récupérer l'actionnaire
  SELECT s.* INTO v_sh
  FROM public.shareholders s WHERE s.user_id = p_user_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'Actionnaire introuvable');
  END IF;

  -- Récupérer l'assignment actif
  SELECT sa.* INTO v_assign
  FROM public.shareholder_assignments sa
  WHERE sa.shareholder_id = v_sh.id AND sa.status = 'active'
  LIMIT 1;

  -- Agréger toutes les données
  SELECT jsonb_build_object(
    'shareholder',   row_to_json(v_sh),
    'assignment',    row_to_json(v_assign),
    'total_revenues', (
      SELECT COALESCE(SUM(sr.total_paid_revenue), 0)
      FROM public.shareholder_revenues sr
      WHERE sr.shareholder_id = v_sh.id
    ),
    'total_earnings', (
      SELECT COALESCE(SUM(sr.shareholder_amount), 0)
      FROM public.shareholder_revenues sr
      WHERE sr.shareholder_id = v_sh.id
    ),
    'pending_payments', (
      SELECT COALESCE(SUM(sp.amount), 0)
      FROM public.shareholder_payments sp
      WHERE sp.shareholder_id = v_sh.id AND sp.status = 'pending'
    ),
    'received_payments', (
      SELECT COALESCE(SUM(sp.amount), 0)
      FROM public.shareholder_payments sp
      WHERE sp.shareholder_id = v_sh.id AND sp.status = 'sent_to_wallet'
    ),
    'unread_notifications', (
      SELECT COUNT(*) FROM public.notifications n
      WHERE n.user_id = p_user_id AND n.read = false
    ),
    'open_votes', (
      SELECT COUNT(*) FROM public.shareholder_votes sv
      WHERE sv.status = 'open'
        AND sv.end_date > now()
        AND (
          sv.target_type = 'all' OR
          (sv.target_type = 'specific_shareholder' AND sv.shareholder_id = v_sh.id) OR
          (sv.target_type = 'category' AND sv.category = v_assign.category) OR
          (sv.target_type = 'country' AND sv.country = v_assign.country) OR
          (sv.target_type = 'global' AND v_assign.action_scope = 'global') OR
          (sv.target_type = 'category_country'
           AND sv.category = v_assign.category
           AND sv.country = v_assign.country)
        )
    ),
    'wallet_balance', (
      SELECT COALESCE(w.balance, 0)
      FROM public.wallets w
      WHERE w.user_id = p_user_id
      LIMIT 1
    )
  ) INTO v_result;

  RETURN v_result;
END;
$$;

-- ============================================================================
-- 18. VUE: STATISTIQUES PDG ACTIONNAIRES
-- ============================================================================

CREATE OR REPLACE VIEW public.shareholder_pdg_stats AS
SELECT
  COUNT(DISTINCT s.id)                                    AS total_shareholders,
  COUNT(DISTINCT s.id) FILTER (WHERE s.status = 'active') AS active_shareholders,
  COUNT(DISTINCT s.id) FILTER (WHERE s.status = 'suspended') AS suspended_shareholders,
  COUNT(DISTINCT sa.id)                                   AS total_assignments,
  COALESCE(SUM(sr.total_paid_revenue), 0)                 AS total_all_revenues,
  COALESCE(SUM(sr.shareholder_amount), 0)                 AS total_all_earnings,
  COALESCE(SUM(sp.amount) FILTER (WHERE sp.status = 'pending'), 0) AS pending_payments,
  COALESCE(SUM(sp.amount) FILTER (WHERE sp.status = 'sent_to_wallet'), 0) AS sent_payments
FROM public.shareholders s
LEFT JOIN public.shareholder_assignments sa ON sa.shareholder_id = s.id
LEFT JOIN public.shareholder_revenues sr ON sr.shareholder_id = s.id
LEFT JOIN public.shareholder_payments sp ON sp.shareholder_id = s.id;

-- ============================================================================
-- 19. VUE: POURCENTAGES PAR CATÉGORIE ET PAYS
-- ============================================================================

CREATE OR REPLACE VIEW public.shareholder_percentage_summary AS
SELECT
  sa.category,
  sa.action_scope,
  sa.country,
  COALESCE(SUM(sa.percentage) FILTER (WHERE sa.status = 'active'), 0) AS used_percentage,
  100 - COALESCE(SUM(sa.percentage) FILTER (WHERE sa.status = 'active'), 0) AS remaining_percentage,
  COUNT(DISTINCT sa.shareholder_id) FILTER (WHERE sa.status = 'active') AS active_shareholders_count
FROM public.shareholder_assignments sa
GROUP BY sa.category, sa.action_scope, sa.country;

-- ============================================================================
-- 20. ROW LEVEL SECURITY (RLS)
-- ============================================================================

-- Activer RLS sur toutes les tables
ALTER TABLE public.shareholders             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shareholder_assignments  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shareholder_revenues     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shareholder_payments     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shareholder_documents    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shareholder_votes        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shareholder_vote_responses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shareholder_audit_logs   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shareholder_monthly_reports ENABLE ROW LEVEL SECURITY;

-- Helper: vérifier si l'utilisateur est PDG/admin
CREATE OR REPLACE FUNCTION public.is_pdg_or_admin()
RETURNS BOOLEAN
LANGUAGE sql SECURITY DEFINER STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid()
      AND role IN ('pdg','admin','ceo')
  );
$$;

-- Helper: obtenir le shareholder_id de l'utilisateur connecté
CREATE OR REPLACE FUNCTION public.get_my_shareholder_id()
RETURNS UUID
LANGUAGE sql SECURITY DEFINER STABLE
AS $$
  SELECT id FROM public.shareholders WHERE user_id = auth.uid() LIMIT 1;
$$;

-- ====== POLICIES shareholders ======
DROP POLICY IF EXISTS "PDG peut tout voir sur shareholders" ON public.shareholders;
CREATE POLICY "PDG peut tout voir sur shareholders" ON public.shareholders
  FOR ALL USING (public.is_pdg_or_admin());

DROP POLICY IF EXISTS "Actionnaire voit son profil" ON public.shareholders;
CREATE POLICY "Actionnaire voit son profil" ON public.shareholders
  FOR SELECT USING (user_id = auth.uid());

-- ====== POLICIES shareholder_assignments ======
DROP POLICY IF EXISTS "PDG tout sur assignments" ON public.shareholder_assignments;
CREATE POLICY "PDG tout sur assignments" ON public.shareholder_assignments
  FOR ALL USING (public.is_pdg_or_admin());

DROP POLICY IF EXISTS "Actionnaire voit son assignment" ON public.shareholder_assignments;
CREATE POLICY "Actionnaire voit son assignment" ON public.shareholder_assignments
  FOR SELECT USING (
    shareholder_id = public.get_my_shareholder_id()
  );

-- ====== POLICIES shareholder_revenues ======
DROP POLICY IF EXISTS "PDG tout sur revenues" ON public.shareholder_revenues;
CREATE POLICY "PDG tout sur revenues" ON public.shareholder_revenues
  FOR ALL USING (public.is_pdg_or_admin());

DROP POLICY IF EXISTS "Actionnaire voit ses revenues" ON public.shareholder_revenues;
CREATE POLICY "Actionnaire voit ses revenues" ON public.shareholder_revenues
  FOR SELECT USING (
    shareholder_id = public.get_my_shareholder_id()
  );

-- ====== POLICIES shareholder_payments ======
DROP POLICY IF EXISTS "PDG tout sur payments" ON public.shareholder_payments;
CREATE POLICY "PDG tout sur payments" ON public.shareholder_payments
  FOR ALL USING (public.is_pdg_or_admin());

DROP POLICY IF EXISTS "Actionnaire voit ses payments" ON public.shareholder_payments;
CREATE POLICY "Actionnaire voit ses payments" ON public.shareholder_payments
  FOR SELECT USING (
    shareholder_id = public.get_my_shareholder_id()
  );

-- ====== POLICIES documents ======
DROP POLICY IF EXISTS "PDG tout sur documents" ON public.shareholder_documents;
CREATE POLICY "PDG tout sur documents" ON public.shareholder_documents
  FOR ALL USING (public.is_pdg_or_admin());

DROP POLICY IF EXISTS "Actionnaire voit ses documents" ON public.shareholder_documents;
CREATE POLICY "Actionnaire voit ses documents" ON public.shareholder_documents
  FOR SELECT USING (
    visibility = 'all' OR
    (visibility = 'specific_shareholder' AND shareholder_id = public.get_my_shareholder_id()) OR
    (visibility IN ('category','category_country') AND category = (
      SELECT sa.category FROM public.shareholder_assignments sa
      WHERE sa.shareholder_id = public.get_my_shareholder_id()
      AND sa.status = 'active' LIMIT 1
    )) OR
    (visibility IN ('country','category_country') AND country = (
      SELECT sa.country FROM public.shareholder_assignments sa
      WHERE sa.shareholder_id = public.get_my_shareholder_id()
      AND sa.status = 'active' LIMIT 1
    )) OR
    (visibility = 'global' AND (
      SELECT sa.action_scope FROM public.shareholder_assignments sa
      WHERE sa.shareholder_id = public.get_my_shareholder_id()
      AND sa.status = 'active' LIMIT 1
    ) = 'global')
  );

-- ====== POLICIES votes ======
DROP POLICY IF EXISTS "PDG tout sur votes" ON public.shareholder_votes;
CREATE POLICY "PDG tout sur votes" ON public.shareholder_votes
  FOR ALL USING (public.is_pdg_or_admin());

DROP POLICY IF EXISTS "Actionnaire voit ses votes" ON public.shareholder_votes;
CREATE POLICY "Actionnaire voit ses votes" ON public.shareholder_votes
  FOR SELECT USING (
    target_type = 'all' OR
    (target_type = 'specific_shareholder' AND shareholder_id = public.get_my_shareholder_id()) OR
    EXISTS (
      SELECT 1 FROM public.shareholder_assignments sa
      WHERE sa.shareholder_id = public.get_my_shareholder_id()
      AND sa.status = 'active'
      AND (
        target_type = 'category' AND sa.category = shareholder_votes.category
        OR
        target_type = 'country' AND sa.country = shareholder_votes.country
        OR
        target_type = 'global' AND sa.action_scope = 'global'
        OR
        target_type = 'category_country' AND sa.category = shareholder_votes.category
          AND sa.country = shareholder_votes.country
      )
    )
  );

-- ====== POLICIES vote_responses ======
DROP POLICY IF EXISTS "PDG tout sur vote_responses" ON public.shareholder_vote_responses;
CREATE POLICY "PDG tout sur vote_responses" ON public.shareholder_vote_responses
  FOR ALL USING (public.is_pdg_or_admin());

DROP POLICY IF EXISTS "Actionnaire gère ses réponses" ON public.shareholder_vote_responses;
CREATE POLICY "Actionnaire gère ses réponses" ON public.shareholder_vote_responses
  FOR ALL USING (
    shareholder_id = public.get_my_shareholder_id()
  );

-- ====== POLICIES audit_logs ======
DROP POLICY IF EXISTS "PDG voit audit logs" ON public.shareholder_audit_logs;
CREATE POLICY "PDG voit audit logs" ON public.shareholder_audit_logs
  FOR ALL USING (public.is_pdg_or_admin());

-- ====== POLICIES monthly_reports ======
DROP POLICY IF EXISTS "PDG tout sur rapports" ON public.shareholder_monthly_reports;
CREATE POLICY "PDG tout sur rapports" ON public.shareholder_monthly_reports
  FOR ALL USING (public.is_pdg_or_admin());

DROP POLICY IF EXISTS "Actionnaire voit ses rapports" ON public.shareholder_monthly_reports;
CREATE POLICY "Actionnaire voit ses rapports" ON public.shareholder_monthly_reports
  FOR SELECT USING (
    shareholder_id = public.get_my_shareholder_id()
  );

-- ====== POLICIES vue stats ======
DROP POLICY IF EXISTS "PDG voit stats" ON public.shareholders;

-- ============================================================================
-- 21. TRIGGERS: MISE À JOUR updated_at AUTOMATIQUE
-- ============================================================================

CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'shareholders_updated_at') THEN
    CREATE TRIGGER shareholders_updated_at
      BEFORE UPDATE ON public.shareholders
      FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'sh_assignments_updated_at') THEN
    CREATE TRIGGER sh_assignments_updated_at
      BEFORE UPDATE ON public.shareholder_assignments
      FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'sh_revenues_updated_at') THEN
    CREATE TRIGGER sh_revenues_updated_at
      BEFORE UPDATE ON public.shareholder_revenues
      FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'sh_payments_updated_at') THEN
    CREATE TRIGGER sh_payments_updated_at
      BEFORE UPDATE ON public.shareholder_payments
      FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
  END IF;
END $$;

-- ============================================================================
-- 22. CRÉER TABLE vendor_subscriptions si elle n'existe pas
--     (pour les actionnaires vendeur)
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.vendor_subscriptions (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  plan_id         UUID REFERENCES public.plans(id),
  status          TEXT NOT NULL DEFAULT 'active'
                  CHECK (status IN ('active','expired','cancelled','suspended')),
  amount_paid     NUMERIC(12,2) DEFAULT 0,
  currency        TEXT DEFAULT 'GNF',
  payment_method  TEXT,
  billing_cycle   TEXT DEFAULT 'monthly',
  offered_by_ceo  BOOLEAN DEFAULT false,
  started_at      TIMESTAMPTZ DEFAULT now(),
  expires_at      TIMESTAMPTZ,
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_vendor_subs_user_id ON public.vendor_subscriptions(user_id);
CREATE INDEX IF NOT EXISTS idx_vendor_subs_status  ON public.vendor_subscriptions(status);

ALTER TABLE public.vendor_subscriptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "PDG tout vendor_subscriptions" ON public.vendor_subscriptions;
CREATE POLICY "PDG tout vendor_subscriptions" ON public.vendor_subscriptions
  FOR ALL USING (public.is_pdg_or_admin());

DROP POLICY IF EXISTS "Utilisateur voit ses abonnements" ON public.vendor_subscriptions;
CREATE POLICY "Utilisateur voit ses abonnements" ON public.vendor_subscriptions
  FOR SELECT USING (user_id = auth.uid());

-- ============================================================================
-- GRANTS
-- ============================================================================

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated;
