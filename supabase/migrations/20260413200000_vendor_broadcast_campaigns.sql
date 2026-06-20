-- ============================================================================
-- VENDOR BROADCAST CAMPAIGNS - Système de diffusion multicanal vendeur
-- 224Solutions - Migration idempotente
-- ============================================================================

-- ============================================================================
-- TABLE 1: vendor_customer_links
-- Relation matérialisée vendeur-client basée sur les données réelles
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.vendor_customer_links (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id uuid NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  customer_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  -- Source de la relation
  source_type text NOT NULL DEFAULT 'digital' CHECK (source_type IN ('digital', 'physical', 'both')),
  linked_via text NOT NULL DEFAULT 'marketplace_order' CHECK (linked_via IN (
    'marketplace_order', 'pos_order', 'loyalty', 'manual', 'booking', 'service_order'
  )),
  store_id uuid NULL,
  -- Coordonnées (snapshot depuis profiles pour performance)
  email text NULL,
  phone text NULL,
  full_name text NULL,
  preferred_language text DEFAULT 'fr',
  -- Consentements
  marketing_email_opt_in boolean DEFAULT true,
  marketing_sms_opt_in boolean DEFAULT true,
  marketing_push_opt_in boolean DEFAULT true,
  marketing_in_app_opt_in boolean DEFAULT true,
  -- Stats agrégées (mises à jour par trigger)
  last_purchase_at timestamptz NULL,
  total_orders int DEFAULT 0,
  total_spent numeric(15,2) DEFAULT 0,
  is_active boolean DEFAULT true,
  -- Métadonnées
  metadata jsonb DEFAULT '{}',
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  -- Un client ne peut être lié qu'une fois à un vendeur
  UNIQUE(vendor_id, customer_user_id)
);

-- Index pour requêtes fréquentes
CREATE INDEX IF NOT EXISTS idx_vcl_vendor_id ON public.vendor_customer_links(vendor_id);
CREATE INDEX IF NOT EXISTS idx_vcl_customer_user_id ON public.vendor_customer_links(customer_user_id);
CREATE INDEX IF NOT EXISTS idx_vcl_vendor_active ON public.vendor_customer_links(vendor_id, is_active);
CREATE INDEX IF NOT EXISTS idx_vcl_vendor_source ON public.vendor_customer_links(vendor_id, source_type);
CREATE INDEX IF NOT EXISTS idx_vcl_last_purchase ON public.vendor_customer_links(vendor_id, last_purchase_at DESC NULLS LAST);
CREATE INDEX IF NOT EXISTS idx_vcl_total_spent ON public.vendor_customer_links(vendor_id, total_spent DESC);

-- ============================================================================
-- TABLE 2: vendor_campaigns
-- Campagnes de diffusion vendeur
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.vendor_campaigns (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id uuid NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  store_id uuid NULL,
  -- Contenu
  title text NOT NULL CHECK (length(title) BETWEEN 3 AND 200),
  subject text NULL CHECK (subject IS NULL OR length(subject) <= 500),
  message_body text NOT NULL CHECK (length(message_body) BETWEEN 1 AND 5000),
  message_html text NULL,
  message_type text DEFAULT 'announcement' CHECK (message_type IN (
    'announcement', 'promotion', 'alert', 'update', 'newsletter', 'reminder'
  )),
  -- Ciblage
  target_type text NOT NULL DEFAULT 'all_clients' CHECK (target_type IN (
    'all_clients', 'digital_only', 'physical_only', 'hybrid',
    'active', 'inactive', 'recent_buyers', 'dormant',
    'vip', 'by_store', 'by_product_category', 'custom'
  )),
  target_filters jsonb DEFAULT '{}',
  -- Canaux sélectionnés
  selected_channels text[] NOT NULL DEFAULT '{in_app}' CHECK (array_length(selected_channels, 1) > 0),
  -- Volumes
  total_targeted int DEFAULT 0,
  total_eligible int DEFAULT 0,
  total_sent int DEFAULT 0,
  total_delivered int DEFAULT 0,
  total_read int DEFAULT 0,
  total_failed int DEFAULT 0,
  total_skipped int DEFAULT 0,
  -- Statut
  status text DEFAULT 'draft' CHECK (status IN (
    'draft', 'scheduled', 'queued', 'sending', 'sent', 'partial', 'failed', 'cancelled'
  )),
  -- Planification
  scheduled_at timestamptz NULL,
  started_at timestamptz NULL,
  completed_at timestamptz NULL,
  -- Métadonnées
  image_url text NULL,
  link_url text NULL,
  link_text text NULL,
  metadata jsonb DEFAULT '{}',
  created_by uuid NOT NULL REFERENCES auth.users(id),
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- Index
CREATE INDEX IF NOT EXISTS idx_vc_vendor_id ON public.vendor_campaigns(vendor_id);
CREATE INDEX IF NOT EXISTS idx_vc_status ON public.vendor_campaigns(vendor_id, status);
CREATE INDEX IF NOT EXISTS idx_vc_created_at ON public.vendor_campaigns(vendor_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_vc_scheduled ON public.vendor_campaigns(status, scheduled_at) WHERE status = 'scheduled';

-- ============================================================================
-- TABLE 3: vendor_campaign_recipients
-- Destinataires d'une campagne (snapshot au moment de l'envoi)
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.vendor_campaign_recipients (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id uuid NOT NULL REFERENCES public.vendor_campaigns(id) ON DELETE CASCADE,
  vendor_id uuid NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  customer_user_id uuid NOT NULL REFERENCES auth.users(id),
  -- Snapshot contact au moment de la campagne
  email text NULL,
  phone text NULL,
  full_name text NULL,
  preferred_language text DEFAULT 'fr',
  -- Snapshot éligibilité
  eligible_channels text[] DEFAULT '{}',
  eligibility_snapshot jsonb DEFAULT '{}',
  created_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_vcr_campaign_id ON public.vendor_campaign_recipients(campaign_id);
CREATE INDEX IF NOT EXISTS idx_vcr_customer ON public.vendor_campaign_recipients(customer_user_id);

-- ============================================================================
-- TABLE 4: vendor_campaign_deliveries
-- Livraisons par canal (un enregistrement par canal par destinataire)
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.vendor_campaign_deliveries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id uuid NOT NULL REFERENCES public.vendor_campaigns(id) ON DELETE CASCADE,
  recipient_id uuid NOT NULL REFERENCES public.vendor_campaign_recipients(id) ON DELETE CASCADE,
  customer_user_id uuid NOT NULL REFERENCES auth.users(id),
  -- Canal
  channel text NOT NULL CHECK (channel IN ('in_app', 'push', 'email', 'sms')),
  -- Provider
  provider text NULL,
  provider_message_id text NULL,
  -- Statut
  status text DEFAULT 'pending' CHECK (status IN (
    'pending', 'queued', 'sent', 'delivered', 'read', 'failed', 'skipped'
  )),
  failure_reason text NULL,
  retry_count int DEFAULT 0,
  max_retries int DEFAULT 3,
  -- Timestamps
  last_attempt_at timestamptz NULL,
  sent_at timestamptz NULL,
  delivered_at timestamptz NULL,
  read_at timestamptz NULL,
  clicked_at timestamptz NULL,
  -- Métadonnées
  metadata jsonb DEFAULT '{}',
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_vcd_campaign_id ON public.vendor_campaign_deliveries(campaign_id);
CREATE INDEX IF NOT EXISTS idx_vcd_recipient ON public.vendor_campaign_deliveries(recipient_id);
CREATE INDEX IF NOT EXISTS idx_vcd_status ON public.vendor_campaign_deliveries(campaign_id, status);
CREATE INDEX IF NOT EXISTS idx_vcd_channel ON public.vendor_campaign_deliveries(campaign_id, channel);
CREATE INDEX IF NOT EXISTS idx_vcd_pending ON public.vendor_campaign_deliveries(status, created_at) WHERE status IN ('pending', 'queued');
CREATE INDEX IF NOT EXISTS idx_vcd_retry ON public.vendor_campaign_deliveries(status, retry_count) WHERE status = 'failed' AND retry_count < 3;

-- ============================================================================
-- TABLE 5: vendor_campaign_audit_logs
-- Logs d'audit pour suivi et anti-abus
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.vendor_campaign_audit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id uuid NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  campaign_id uuid NULL REFERENCES public.vendor_campaigns(id) ON DELETE SET NULL,
  action text NOT NULL CHECK (action IN (
    'campaign_created', 'campaign_sent', 'campaign_cancelled',
    'batch_processed', 'delivery_failed', 'delivery_sent',
    'rate_limit_hit', 'quota_exceeded', 'abuse_detected',
    'campaign_suspended', 'vendor_blocked'
  )),
  details jsonb DEFAULT '{}',
  ip_address text NULL,
  user_agent text NULL,
  created_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_vcal_vendor ON public.vendor_campaign_audit_logs(vendor_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_vcal_action ON public.vendor_campaign_audit_logs(action, created_at DESC);

-- ============================================================================
-- TABLE 6: vendor_campaign_quotas
-- Quotas/limites par vendeur (configurable par plan d'abonnement)
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.vendor_campaign_quotas (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id uuid NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE UNIQUE,
  -- Limites
  max_campaigns_per_day int DEFAULT 5,
  max_campaigns_per_month int DEFAULT 50,
  max_recipients_per_campaign int DEFAULT 500,
  max_sms_per_month int DEFAULT 100,
  max_emails_per_month int DEFAULT 1000,
  -- Compteurs (reset automatique)
  campaigns_today int DEFAULT 0,
  campaigns_this_month int DEFAULT 0,
  sms_this_month int DEFAULT 0,
  emails_this_month int DEFAULT 0,
  last_campaign_at timestamptz NULL,
  -- Anti-spam
  is_suspended boolean DEFAULT false,
  suspended_reason text NULL,
  suspended_at timestamptz NULL,
  suspended_by uuid NULL,
  -- Métadonnées
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- ============================================================================
-- RLS POLICIES
-- ============================================================================

-- Activer RLS sur toutes les tables
ALTER TABLE public.vendor_customer_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vendor_campaigns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vendor_campaign_recipients ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vendor_campaign_deliveries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vendor_campaign_audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vendor_campaign_quotas ENABLE ROW LEVEL SECURITY;

-- === vendor_customer_links ===
-- Vendeur voit ses propres liens clients
CREATE POLICY vcl_vendor_select ON public.vendor_customer_links
  FOR SELECT USING (
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
    OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role IN ('admin', 'pdg', 'ceo'))
  );

CREATE POLICY vcl_vendor_insert ON public.vendor_customer_links
  FOR INSERT WITH CHECK (
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  );

CREATE POLICY vcl_vendor_update ON public.vendor_customer_links
  FOR UPDATE USING (
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  );

-- === vendor_campaigns ===
-- Vendeur voit ses propres campagnes
CREATE POLICY vc_vendor_select ON public.vendor_campaigns
  FOR SELECT USING (
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
    OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role IN ('admin', 'pdg', 'ceo'))
  );

CREATE POLICY vc_vendor_insert ON public.vendor_campaigns
  FOR INSERT WITH CHECK (
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
    AND created_by = auth.uid()
  );

CREATE POLICY vc_vendor_update ON public.vendor_campaigns
  FOR UPDATE USING (
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  );

-- === vendor_campaign_recipients ===
CREATE POLICY vcr_vendor_select ON public.vendor_campaign_recipients
  FOR SELECT USING (
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
    OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role IN ('admin', 'pdg', 'ceo'))
  );

-- Insert only by service role (backend)
CREATE POLICY vcr_service_insert ON public.vendor_campaign_recipients
  FOR INSERT WITH CHECK (
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  );

-- === vendor_campaign_deliveries ===
CREATE POLICY vcd_vendor_select ON public.vendor_campaign_deliveries
  FOR SELECT USING (
    campaign_id IN (
      SELECT id FROM public.vendor_campaigns 
      WHERE vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
    )
    OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role IN ('admin', 'pdg', 'ceo'))
  );

-- === vendor_campaign_audit_logs ===
CREATE POLICY vcal_vendor_select ON public.vendor_campaign_audit_logs
  FOR SELECT USING (
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
    OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role IN ('admin', 'pdg', 'ceo'))
  );

-- === vendor_campaign_quotas ===
CREATE POLICY vcq_vendor_select ON public.vendor_campaign_quotas
  FOR SELECT USING (
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
    OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role IN ('admin', 'pdg', 'ceo'))
  );

CREATE POLICY vcq_admin_all ON public.vendor_campaign_quotas
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role IN ('admin', 'pdg', 'ceo'))
  );

-- ============================================================================
-- FUNCTION: Sync vendor_customer_links from orders
-- Matérialise les relations vendeur-client depuis les commandes réelles
-- ============================================================================
CREATE OR REPLACE FUNCTION public.sync_vendor_customer_link()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_customer_user_id uuid;
  v_email text;
  v_phone text;
  v_full_name text;
  v_source text;
BEGIN
  -- Récupérer le user_id du customer
  SELECT c.user_id INTO v_customer_user_id
  FROM customers c WHERE c.id = NEW.customer_id;
  
  IF v_customer_user_id IS NULL THEN RETURN NEW; END IF;
  
  -- Récupérer les infos du profil
  SELECT p.email, p.phone, COALESCE(p.first_name || ' ' || p.last_name, p.email)
  INTO v_email, v_phone, v_full_name
  FROM profiles p WHERE p.id = v_customer_user_id;
  
  -- Déterminer la source
  v_source := CASE 
    WHEN NEW.source = 'pos' THEN 'physical'
    WHEN NEW.source = 'online' THEN 'digital'
    ELSE 'digital'
  END;
  
  -- Upsert la relation
  INSERT INTO vendor_customer_links (
    vendor_id, customer_user_id, source_type, linked_via,
    email, phone, full_name,
    last_purchase_at, total_orders, total_spent
  ) VALUES (
    NEW.vendor_id, v_customer_user_id, v_source,
    CASE WHEN NEW.source = 'pos' THEN 'pos_order' ELSE 'marketplace_order' END,
    v_email, v_phone, v_full_name,
    NEW.created_at, 1, COALESCE(NEW.total_amount, 0)
  )
  ON CONFLICT (vendor_id, customer_user_id) DO UPDATE SET
    -- Upgrade source_type si nécessaire
    source_type = CASE 
      WHEN vendor_customer_links.source_type = 'both' THEN 'both'
      WHEN vendor_customer_links.source_type != EXCLUDED.source_type THEN 'both'
      ELSE EXCLUDED.source_type
    END,
    last_purchase_at = GREATEST(vendor_customer_links.last_purchase_at, NEW.created_at),
    total_orders = vendor_customer_links.total_orders + 1,
    total_spent = vendor_customer_links.total_spent + COALESCE(NEW.total_amount, 0),
    email = COALESCE(EXCLUDED.email, vendor_customer_links.email),
    phone = COALESCE(EXCLUDED.phone, vendor_customer_links.phone),
    full_name = COALESCE(EXCLUDED.full_name, vendor_customer_links.full_name),
    is_active = true,
    updated_at = now();
  
  RETURN NEW;
END;
$$;

-- Trigger sur création de commande
DROP TRIGGER IF EXISTS trg_sync_vendor_customer_link ON public.orders;
CREATE TRIGGER trg_sync_vendor_customer_link
  AFTER INSERT ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_vendor_customer_link();

-- ============================================================================
-- FUNCTION: Initialiser les liens depuis les commandes existantes
-- À exécuter une fois pour remplir vendor_customer_links
-- ============================================================================
CREATE OR REPLACE FUNCTION public.backfill_vendor_customer_links()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count int := 0;
BEGIN
  INSERT INTO vendor_customer_links (
    vendor_id, customer_user_id, source_type, linked_via,
    email, phone, full_name,
    last_purchase_at, total_orders, total_spent
  )
  SELECT 
    o.vendor_id,
    c.user_id,
    CASE 
      WHEN bool_or(o.source = 'pos') AND bool_or(o.source = 'online') THEN 'both'
      WHEN bool_or(o.source = 'pos') THEN 'physical'
      ELSE 'digital'
    END,
    CASE 
      WHEN bool_or(o.source = 'pos') THEN 'pos_order'
      ELSE 'marketplace_order'
    END,
    p.email,
    p.phone,
    COALESCE(p.first_name || ' ' || p.last_name, p.email),
    MAX(o.created_at),
    COUNT(o.id)::int,
    COALESCE(SUM(o.total_amount), 0)
  FROM orders o
  JOIN customers c ON c.id = o.customer_id
  JOIN profiles p ON p.id = c.user_id
  WHERE o.vendor_id IS NOT NULL
    AND o.status NOT IN ('cancelled', 'refunded')
  GROUP BY o.vendor_id, c.user_id, p.email, p.phone, p.first_name, p.last_name
  ON CONFLICT (vendor_id, customer_user_id) DO UPDATE SET
    last_purchase_at = GREATEST(vendor_customer_links.last_purchase_at, EXCLUDED.last_purchase_at),
    total_orders = EXCLUDED.total_orders,
    total_spent = EXCLUDED.total_spent,
    email = COALESCE(EXCLUDED.email, vendor_customer_links.email),
    phone = COALESCE(EXCLUDED.phone, vendor_customer_links.phone),
    full_name = COALESCE(EXCLUDED.full_name, vendor_customer_links.full_name),
    updated_at = now();

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

-- ============================================================================
-- FUNCTION: Preview audience count for campaign targeting
-- ============================================================================
CREATE OR REPLACE FUNCTION public.preview_campaign_audience(
  p_vendor_id uuid,
  p_target_type text DEFAULT 'all_clients',
  p_target_filters jsonb DEFAULT '{}'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_total int := 0;
  v_with_email int := 0;
  v_with_phone int := 0;
  v_with_push int := 0;
  v_in_app int := 0;
BEGIN
  -- Total matching target type
  SELECT COUNT(*) INTO v_total
  FROM vendor_customer_links vcl
  WHERE vcl.vendor_id = p_vendor_id
    AND vcl.is_active = true
    AND (
      p_target_type = 'all_clients'
      OR (p_target_type = 'digital_only' AND vcl.source_type IN ('digital', 'both'))
      OR (p_target_type = 'physical_only' AND vcl.source_type IN ('physical', 'both'))
      OR (p_target_type = 'hybrid' AND vcl.source_type = 'both')
      OR (p_target_type = 'active' AND vcl.last_purchase_at >= (now() - interval '30 days'))
      OR (p_target_type = 'inactive' AND (vcl.last_purchase_at IS NULL OR vcl.last_purchase_at < (now() - interval '90 days')))
      OR (p_target_type = 'recent_buyers' AND vcl.last_purchase_at >= (now() - interval '7 days'))
      OR (p_target_type = 'dormant' AND vcl.last_purchase_at < (now() - interval '180 days'))
      OR (p_target_type = 'vip' AND (vcl.total_spent > 500000 OR vcl.total_orders > 10))
      OR p_target_type = 'custom'
    )
    AND (
      p_target_filters = '{}'::jsonb
      OR (
        (p_target_filters->>'min_orders' IS NULL OR vcl.total_orders >= (p_target_filters->>'min_orders')::int)
        AND (p_target_filters->>'min_spent' IS NULL OR vcl.total_spent >= (p_target_filters->>'min_spent')::numeric)
        AND (p_target_filters->>'days_since_purchase' IS NULL OR vcl.last_purchase_at >= (now() - ((p_target_filters->>'days_since_purchase') || ' days')::interval))
      )
    );

  -- Count with email
  SELECT COUNT(*) INTO v_with_email
  FROM vendor_customer_links vcl
  WHERE vcl.vendor_id = p_vendor_id AND vcl.is_active = true
    AND vcl.email IS NOT NULL AND vcl.marketing_email_opt_in = true;

  -- Count with phone
  SELECT COUNT(*) INTO v_with_phone
  FROM vendor_customer_links vcl
  WHERE vcl.vendor_id = p_vendor_id AND vcl.is_active = true
    AND vcl.phone IS NOT NULL AND vcl.marketing_sms_opt_in = true;

  -- In-app is always available for all linked users
  v_in_app := v_total;
  -- Push count approximated as in_app (tokens checked at send time)
  v_with_push := v_total;

  RETURN jsonb_build_object(
    'total', v_total,
    'channels', jsonb_build_object(
      'in_app', v_in_app,
      'push', v_with_push,
      'email', v_with_email,
      'sms', v_with_phone
    )
  );
END;
$$;

-- ============================================================================
-- FUNCTION: Reset daily/monthly quotas (called by cron)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.reset_campaign_quotas_daily()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE vendor_campaign_quotas SET campaigns_today = 0, updated_at = now();
END;
$$;

CREATE OR REPLACE FUNCTION public.reset_campaign_quotas_monthly()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE vendor_campaign_quotas 
  SET campaigns_this_month = 0, sms_this_month = 0, emails_this_month = 0, updated_at = now();
END;
$$;

-- ============================================================================
-- Updated_at trigger
-- ============================================================================
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_vcl_updated ON public.vendor_customer_links;
CREATE TRIGGER trg_vcl_updated BEFORE UPDATE ON public.vendor_customer_links
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS trg_vc_updated ON public.vendor_campaigns;
CREATE TRIGGER trg_vc_updated BEFORE UPDATE ON public.vendor_campaigns
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS trg_vcd_updated ON public.vendor_campaign_deliveries;
CREATE TRIGGER trg_vcd_updated BEFORE UPDATE ON public.vendor_campaign_deliveries
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS trg_vcq_updated ON public.vendor_campaign_quotas;
CREATE TRIGGER trg_vcq_updated BEFORE UPDATE ON public.vendor_campaign_quotas
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- ============================================================================
-- FUNCTION: Incrémenter le compteur de campagnes du quota vendeur
-- ============================================================================
CREATE OR REPLACE FUNCTION public.increment_campaign_quota(p_vendor_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  INSERT INTO public.vendor_campaign_quotas (vendor_id, campaigns_today, campaigns_this_month)
  VALUES (p_vendor_id, 1, 1)
  ON CONFLICT (vendor_id) DO UPDATE SET
    campaigns_today = vendor_campaign_quotas.campaigns_today + 1,
    campaigns_this_month = vendor_campaign_quotas.campaigns_this_month + 1,
    updated_at = now();
END;
$$;

-- ============================================================================
-- FUNCTION: Incrémenter le compteur SMS du quota vendeur
-- ============================================================================
CREATE OR REPLACE FUNCTION public.increment_sms_quota(p_vendor_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  INSERT INTO public.vendor_campaign_quotas (vendor_id, sms_this_month)
  VALUES (p_vendor_id, 1)
  ON CONFLICT (vendor_id) DO UPDATE SET
    sms_this_month = vendor_campaign_quotas.sms_this_month + 1,
    updated_at = now();
END;
$$;
