
-- Table pour les demandes d'accès API 224Wallet
CREATE TABLE public.wallet_api_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  professional_service_id UUID REFERENCES public.professional_services(id) ON DELETE CASCADE NOT NULL,
  business_name TEXT NOT NULL,
  website_url TEXT,
  use_case TEXT NOT NULL,
  expected_volume TEXT,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
  reviewed_by UUID REFERENCES auth.users(id),
  reviewed_at TIMESTAMPTZ,
  rejection_reason TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(professional_service_id)
);

-- Table pour les clés API 224Wallet générées
CREATE TABLE public.wallet_api_keys (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id UUID REFERENCES public.wallet_api_requests(id) ON DELETE CASCADE NOT NULL,
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  professional_service_id UUID REFERENCES public.professional_services(id) ON DELETE CASCADE NOT NULL,
  api_key TEXT NOT NULL UNIQUE,
  api_secret TEXT NOT NULL,
  key_name TEXT NOT NULL DEFAULT '224Wallet Payment API',
  is_active BOOLEAN DEFAULT true,
  is_test_mode BOOLEAN DEFAULT true,
  allowed_domains TEXT[] DEFAULT '{}',
  rate_limit_per_minute INTEGER DEFAULT 30,
  rate_limit_per_day INTEGER DEFAULT 1000,
  commission_rate NUMERIC(5,2) DEFAULT 2.5,
  total_transactions INTEGER DEFAULT 0,
  total_volume_gnf BIGINT DEFAULT 0,
  last_used_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Table pour les transactions API
CREATE TABLE public.wallet_api_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  api_key_id UUID REFERENCES public.wallet_api_keys(id) ON DELETE SET NULL,
  professional_service_id UUID NOT NULL,
  payer_identifier TEXT NOT NULL,
  amount_gnf BIGINT NOT NULL,
  commission_gnf BIGINT DEFAULT 0,
  net_amount_gnf BIGINT DEFAULT 0,
  currency TEXT DEFAULT 'GNF',
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'completed', 'failed', 'refunded')),
  payment_reference TEXT UNIQUE,
  description TEXT,
  metadata JSONB DEFAULT '{}',
  error_message TEXT,
  completed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- RLS
ALTER TABLE public.wallet_api_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallet_api_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallet_api_transactions ENABLE ROW LEVEL SECURITY;

-- Policies: utilisateurs voient leurs propres données
CREATE POLICY "Users can view own api requests" ON public.wallet_api_requests
  FOR SELECT TO authenticated USING (auth.uid() = user_id);

CREATE POLICY "Users can create api requests" ON public.wallet_api_requests
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can view own api keys" ON public.wallet_api_keys
  FOR SELECT TO authenticated USING (auth.uid() = user_id);

CREATE POLICY "Users can view own api transactions" ON public.wallet_api_transactions
  FOR SELECT TO authenticated USING (
    api_key_id IN (SELECT id FROM public.wallet_api_keys WHERE user_id = auth.uid())
  );

-- PDG full access
CREATE POLICY "PDG can manage api requests" ON public.wallet_api_requests
  FOR ALL TO authenticated USING (
    EXISTS (SELECT 1 FROM public.pdg_management WHERE user_id = auth.uid() AND is_active = true)
  );

CREATE POLICY "PDG can manage api keys" ON public.wallet_api_keys
  FOR ALL TO authenticated USING (
    EXISTS (SELECT 1 FROM public.pdg_management WHERE user_id = auth.uid() AND is_active = true)
  );

CREATE POLICY "PDG can view all api transactions" ON public.wallet_api_transactions
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM public.pdg_management WHERE user_id = auth.uid() AND is_active = true)
  );

-- Index
CREATE INDEX idx_wallet_api_requests_status ON public.wallet_api_requests(status);
CREATE INDEX idx_wallet_api_keys_api_key ON public.wallet_api_keys(api_key);
CREATE INDEX idx_wallet_api_transactions_ref ON public.wallet_api_transactions(payment_reference);
