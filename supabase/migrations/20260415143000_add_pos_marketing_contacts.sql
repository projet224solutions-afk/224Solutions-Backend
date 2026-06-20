-- ============================================================================
-- POS MARKETING CONTACTS
-- Collecte de contacts externes (email / téléphone) au POS pour campagnes
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.vendor_marketing_contacts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id uuid NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  store_id uuid NULL,
  contact_type text NOT NULL CHECK (contact_type IN ('email', 'phone')),
  normalized_contact text NOT NULL,
  email text NULL,
  phone text NULL,
  full_name text NULL,
  source_type text NOT NULL DEFAULT 'physical' CHECK (source_type IN ('digital', 'physical', 'both')),
  linked_via text NOT NULL DEFAULT 'pos_order' CHECK (linked_via IN (
    'marketplace_order', 'pos_order', 'manual', 'campaign_import'
  )),
  preferred_language text DEFAULT 'fr',
  marketing_email_opt_in boolean DEFAULT true,
  marketing_sms_opt_in boolean DEFAULT true,
  marketing_push_opt_in boolean DEFAULT false,
  marketing_in_app_opt_in boolean DEFAULT false,
  last_purchase_at timestamptz NULL,
  total_orders int DEFAULT 0,
  total_spent numeric(15,2) DEFAULT 0,
  is_active boolean DEFAULT true,
  metadata jsonb DEFAULT '{}',
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  UNIQUE(vendor_id, normalized_contact)
);

CREATE INDEX IF NOT EXISTS idx_vmc_vendor_id ON public.vendor_marketing_contacts(vendor_id);
CREATE INDEX IF NOT EXISTS idx_vmc_vendor_active ON public.vendor_marketing_contacts(vendor_id, is_active);
CREATE INDEX IF NOT EXISTS idx_vmc_contact_type ON public.vendor_marketing_contacts(vendor_id, contact_type);
CREATE INDEX IF NOT EXISTS idx_vmc_last_purchase ON public.vendor_marketing_contacts(vendor_id, last_purchase_at DESC NULLS LAST);

ALTER TABLE public.vendor_marketing_contacts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS vmc_vendor_select ON public.vendor_marketing_contacts;
CREATE POLICY vmc_vendor_select ON public.vendor_marketing_contacts
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.vendors v
      WHERE v.id = vendor_marketing_contacts.vendor_id AND v.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS vmc_vendor_insert ON public.vendor_marketing_contacts;
CREATE POLICY vmc_vendor_insert ON public.vendor_marketing_contacts
  FOR INSERT WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.vendors v
      WHERE v.id = vendor_marketing_contacts.vendor_id AND v.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS vmc_vendor_update ON public.vendor_marketing_contacts;
CREATE POLICY vmc_vendor_update ON public.vendor_marketing_contacts
  FOR UPDATE USING (
    EXISTS (
      SELECT 1 FROM public.vendors v
      WHERE v.id = vendor_marketing_contacts.vendor_id AND v.user_id = auth.uid()
    )
  );

ALTER TABLE public.vendor_campaign_recipients
  ALTER COLUMN customer_user_id DROP NOT NULL;

ALTER TABLE public.vendor_campaign_recipients
  ADD COLUMN IF NOT EXISTS external_contact_id uuid NULL REFERENCES public.vendor_marketing_contacts(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_vcr_external_contact ON public.vendor_campaign_recipients(external_contact_id);

ALTER TABLE public.vendor_campaign_deliveries
  ALTER COLUMN customer_user_id DROP NOT NULL;

ALTER TABLE public.vendor_campaign_deliveries
  ADD COLUMN IF NOT EXISTS external_contact_id uuid NULL REFERENCES public.vendor_marketing_contacts(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_vcd_external_contact ON public.vendor_campaign_deliveries(external_contact_id);
