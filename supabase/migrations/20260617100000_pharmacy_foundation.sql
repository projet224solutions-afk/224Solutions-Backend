-- ============================================================================
-- SERVICE PHARMACIE — PHASE 1 : FONDATION (additif, ne touche aucun service existant).
--
-- Nouveau service_type 'pharmacie' (distinct du service 'sante') + tables métier liées à
-- professional_services (le pharmacien = un professional_services, comme restaurant/beauté) +
-- RLS scopé (réutilise is_service_owner_or_agent) + 4 plans d'abonnement.
--
-- Flux métier : ordonnance scannée → validation MANUELLE par le pharmacien → devis → paiement
-- atomique → préparation → livraison/retrait. Sécurité médicale : aucune délivrance de médicament
-- sous ordonnance sans ordonnance validée (appliqué par la RPC de paiement, phase 2).
-- ============================================================================

-- 1) Type de service 'pharmacie' (catégorie Santé). Idempotent.
INSERT INTO public.service_types (id, code, name, description, icon, category, is_active, commission_rate, features)
SELECT 'b8f7e6d5-c4a3-4b21-9e0f-1a2b3c4d5e6f', 'pharmacie', 'Pharmacie',
       'Pharmacie : ordonnances scannées, validation pharmacien, médicaments, livraison',
       'Pill', 'Santé', true, 10,
       to_jsonb(ARRAY['Validation d''ordonnances','Catalogue de médicaments','Livraison à domicile','Pharmacie de garde'])
WHERE NOT EXISTS (SELECT 1 FROM public.service_types WHERE code = 'pharmacie');

-- 2) Plans d'abonnement pharmacie (4 paliers). Idempotent par (service_type_id, name).
INSERT INTO public.service_plans
  (service_type_id, name, display_name, description, monthly_price_gnf, yearly_price_gnf,
   commission_rate, max_bookings_per_month, max_products, priority_listing, analytics_access,
   can_upload_video, is_active, display_order, features)
SELECT st.id, v.name, v.display_name, v.description, v.monthly, v.yearly, v.commission,
       v.max_ord, v.max_med, v.priority, v.analytics, false, true, v.ord, to_jsonb(v.features)
FROM public.service_types st
CROSS JOIN (VALUES
  ('free',    'Gratuit', '10 ordonnances/mois, sans livraison',                    0,       0,        15, 10,   30,     false, false, 1, ARRAY['10 ordonnances/mois','Sans livraison','Visible en bas des résultats']),
  ('basic',   'Basic',   '50 ordonnances/mois, livraison, 100 médicaments',        12000,   122400,   12, 50,   100,    false, false, 2, ARRAY['50 ordonnances/mois','Livraison','Catalogue 100 médicaments']),
  ('pro',     'Pro',     'Ordonnances illimitées, catalogue illimité, de garde',   30000,   306000,   8,  NULL, 999999, false, true,  3, ARRAY['Ordonnances illimitées','Catalogue illimité','Badge Partenaire','Analytics','Pharmacie de garde','Visible en priorité']),
  ('premium', 'Premium', 'Tout Pro + Certifiée, maladies chroniques, renouvellement', 60000, 612000,   5,  NULL, 999999, true,  true,  4, ARRAY['Tout Pro','Badge Certifiée','Mise en avant','Gestion maladies chroniques','Renouvellement auto'])
) AS v(name, display_name, description, monthly, yearly, commission, max_ord, max_med, priority, analytics, ord, features)
WHERE st.code = 'pharmacie'
  AND NOT EXISTS (SELECT 1 FROM public.service_plans sp WHERE sp.service_type_id = st.id AND sp.name = v.name);

-- 3) Tables métier (liées à professional_services = la pharmacie).
CREATE TABLE IF NOT EXISTS public.prescriptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  pharmacy_id UUID REFERENCES public.professional_services(id) ON DELETE CASCADE,
  photos TEXT[] NOT NULL DEFAULT '{}',
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','reviewing','validated','quoted','refused','expired')),
  pharmacist_notes TEXT,
  refuse_reason TEXT,
  medications_validated JSONB NOT NULL DEFAULT '[]',
  total_quoted NUMERIC(12,2),
  delivery_type TEXT CHECK (delivery_type IN ('delivery','pickup')),
  delivery_address TEXT,
  customer_name TEXT,
  customer_phone TEXT,
  validated_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.pharmacy_orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  pharmacy_id UUID REFERENCES public.professional_services(id) ON DELETE CASCADE,
  prescription_id UUID REFERENCES public.prescriptions(id) ON DELETE SET NULL,
  amount NUMERIC(12,2) NOT NULL,
  commission NUMERIC(12,2) NOT NULL DEFAULT 0,
  delivery_fee NUMERIC(12,2) NOT NULL DEFAULT 0,
  delivery_fee_paid_by TEXT NOT NULL DEFAULT 'client',
  medications JSONB NOT NULL DEFAULT '[]',
  delivery_type TEXT CHECK (delivery_type IN ('delivery','pickup')),
  delivery_address TEXT,
  status TEXT NOT NULL DEFAULT 'preparing' CHECK (status IN ('preparing','ready','delivering','delivered','collected','cancelled')),
  payment_status TEXT NOT NULL DEFAULT 'paid',
  idempotency_key TEXT UNIQUE,
  result JSONB,
  prescription_stamped BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.pharmacy_medications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id UUID REFERENCES public.professional_services(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  dosage TEXT,
  form TEXT,
  price NUMERIC(12,2),
  stock INTEGER NOT NULL DEFAULT 0,
  requires_prescription BOOLEAN NOT NULL DEFAULT true,
  generic_equivalents TEXT[] NOT NULL DEFAULT '{}',
  low_stock_threshold INTEGER NOT NULL DEFAULT 5,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.medication_reminders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  medication_name TEXT NOT NULL,
  times TIME[] NOT NULL DEFAULT '{}',
  frequency TEXT,
  duration_days INTEGER,
  active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.pharmacy_oncall (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id UUID REFERENCES public.professional_services(id) ON DELETE CASCADE,
  oncall_date DATE NOT NULL,
  start_time TIME,
  end_time TIME,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (pharmacy_id, oncall_date)
);

CREATE INDEX IF NOT EXISTS idx_prescriptions_client ON public.prescriptions(client_id);
CREATE INDEX IF NOT EXISTS idx_prescriptions_pharmacy ON public.prescriptions(pharmacy_id);
CREATE INDEX IF NOT EXISTS idx_prescriptions_status ON public.prescriptions(status);
CREATE INDEX IF NOT EXISTS idx_pharmacy_orders_client ON public.pharmacy_orders(client_id);
CREATE INDEX IF NOT EXISTS idx_pharmacy_orders_pharmacy ON public.pharmacy_orders(pharmacy_id);
CREATE INDEX IF NOT EXISTS idx_pharmacy_medications_pharmacy ON public.pharmacy_medications(pharmacy_id);
CREATE INDEX IF NOT EXISTS idx_pharmacy_oncall_date ON public.pharmacy_oncall(oncall_date);

-- 4) RLS — scopé (pas de policy permissive). Le pharmacien (propriétaire du service) via
--    is_service_owner_or_agent ; le client sur ses propres lignes ; service_role plein accès.
ALTER TABLE public.prescriptions        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pharmacy_orders      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pharmacy_medications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.medication_reminders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pharmacy_oncall      ENABLE ROW LEVEL SECURITY;

-- prescriptions : client (les siennes) + pharmacien (celles de son service).
DROP POLICY IF EXISTS prescriptions_client ON public.prescriptions;
CREATE POLICY prescriptions_client ON public.prescriptions FOR ALL
  USING (client_id = auth.uid()) WITH CHECK (client_id = auth.uid());
DROP POLICY IF EXISTS prescriptions_pharmacy ON public.prescriptions;
CREATE POLICY prescriptions_pharmacy ON public.prescriptions FOR ALL
  USING (public.is_service_owner_or_agent(pharmacy_id)) WITH CHECK (public.is_service_owner_or_agent(pharmacy_id));
DROP POLICY IF EXISTS prescriptions_service_role ON public.prescriptions;
CREATE POLICY prescriptions_service_role ON public.prescriptions FOR ALL TO service_role USING (true) WITH CHECK (true);

-- pharmacy_orders : client (les siennes) + pharmacien.
DROP POLICY IF EXISTS pharmacy_orders_client ON public.pharmacy_orders;
CREATE POLICY pharmacy_orders_client ON public.pharmacy_orders FOR SELECT USING (client_id = auth.uid());
DROP POLICY IF EXISTS pharmacy_orders_pharmacy ON public.pharmacy_orders;
CREATE POLICY pharmacy_orders_pharmacy ON public.pharmacy_orders FOR ALL
  USING (public.is_service_owner_or_agent(pharmacy_id)) WITH CHECK (public.is_service_owner_or_agent(pharmacy_id));
DROP POLICY IF EXISTS pharmacy_orders_service_role ON public.pharmacy_orders;
CREATE POLICY pharmacy_orders_service_role ON public.pharmacy_orders FOR ALL TO service_role USING (true) WITH CHECK (true);

-- pharmacy_medications : catalogue lisible publiquement (trouver une pharmacie) ; géré par le pharmacien.
DROP POLICY IF EXISTS pharmacy_medications_public_read ON public.pharmacy_medications;
CREATE POLICY pharmacy_medications_public_read ON public.pharmacy_medications FOR SELECT USING (true);
DROP POLICY IF EXISTS pharmacy_medications_manage ON public.pharmacy_medications;
CREATE POLICY pharmacy_medications_manage ON public.pharmacy_medications FOR ALL
  USING (public.is_service_owner_or_agent(pharmacy_id)) WITH CHECK (public.is_service_owner_or_agent(pharmacy_id));

-- medication_reminders : strictement privé au client.
DROP POLICY IF EXISTS medication_reminders_owner ON public.medication_reminders;
CREATE POLICY medication_reminders_owner ON public.medication_reminders FOR ALL
  USING (client_id = auth.uid()) WITH CHECK (client_id = auth.uid());

-- pharmacy_oncall : lisible publiquement (pharmacies de garde) ; géré par le pharmacien.
DROP POLICY IF EXISTS pharmacy_oncall_public_read ON public.pharmacy_oncall;
CREATE POLICY pharmacy_oncall_public_read ON public.pharmacy_oncall FOR SELECT USING (true);
DROP POLICY IF EXISTS pharmacy_oncall_manage ON public.pharmacy_oncall;
CREATE POLICY pharmacy_oncall_manage ON public.pharmacy_oncall FOR ALL
  USING (public.is_service_owner_or_agent(pharmacy_id)) WITH CHECK (public.is_service_owner_or_agent(pharmacy_id));

SELECT 'Pharmacie Phase 1 : service_type + 4 plans + 5 tables (prescriptions, pharmacy_orders, pharmacy_medications, medication_reminders, pharmacy_oncall) + RLS scopé.' AS status;
