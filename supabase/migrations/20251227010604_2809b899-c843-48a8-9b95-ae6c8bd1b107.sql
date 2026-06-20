-- Table pour les règles WAF
CREATE TABLE public.waf_rules (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT,
  rule_type TEXT NOT NULL CHECK (rule_type IN ('sql_injection', 'xss', 'ddos', 'rate_limit', 'custom', 'bot_protection')),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'testing')),
  blocked_requests INTEGER DEFAULT 0,
  pattern TEXT,
  action TEXT DEFAULT 'block' CHECK (action IN ('block', 'challenge', 'log', 'allow')),
  priority INTEGER DEFAULT 100,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Table pour les logs WAF en temps réel
CREATE TABLE public.waf_logs (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  rule_id UUID REFERENCES public.waf_rules(id),
  ip_address INET NOT NULL,
  request_path TEXT,
  request_method TEXT,
  user_agent TEXT,
  threat_type TEXT,
  action_taken TEXT NOT NULL CHECK (action_taken IN ('blocked', 'challenged', 'logged', 'allowed')),
  country_code TEXT,
  metadata JSONB,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Table pour les statistiques WAF agrégées
CREATE TABLE public.waf_stats (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  date DATE NOT NULL DEFAULT CURRENT_DATE,
  total_requests BIGINT DEFAULT 0,
  blocked_requests BIGINT DEFAULT 0,
  challenged_requests BIGINT DEFAULT 0,
  allowed_requests BIGINT DEFAULT 0,
  unique_ips INTEGER DEFAULT 0,
  top_threats JSONB,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  UNIQUE(date)
);

-- Enable RLS
ALTER TABLE public.waf_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.waf_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.waf_stats ENABLE ROW LEVEL SECURITY;

-- Policies pour admin/ceo seulement (utilisation du bon enum)
CREATE POLICY "Admins can manage WAF rules" ON public.waf_rules
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.profiles 
      WHERE id = auth.uid() AND role IN ('admin', 'ceo')
    )
  );

CREATE POLICY "Admins can view WAF logs" ON public.waf_logs
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.profiles 
      WHERE id = auth.uid() AND role IN ('admin', 'ceo')
    )
  );

CREATE POLICY "Admins can view WAF stats" ON public.waf_stats
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.profiles 
      WHERE id = auth.uid() AND role IN ('admin', 'ceo')
    )
  );

-- Trigger to update waf_rules blocked count
CREATE OR REPLACE FUNCTION public.update_waf_rule_blocked_count()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.action_taken = 'blocked' AND NEW.rule_id IS NOT NULL THEN
    UPDATE public.waf_rules 
    SET blocked_requests = blocked_requests + 1,
        updated_at = now()
    WHERE id = NEW.rule_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER on_waf_log_insert
  AFTER INSERT ON public.waf_logs
  FOR EACH ROW
  EXECUTE FUNCTION public.update_waf_rule_blocked_count();

-- Function to update daily stats
CREATE OR REPLACE FUNCTION public.update_waf_daily_stats()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.waf_stats (date, total_requests, blocked_requests, challenged_requests, allowed_requests)
  VALUES (CURRENT_DATE, 1, 
    CASE WHEN NEW.action_taken = 'blocked' THEN 1 ELSE 0 END,
    CASE WHEN NEW.action_taken = 'challenged' THEN 1 ELSE 0 END,
    CASE WHEN NEW.action_taken = 'allowed' THEN 1 ELSE 0 END
  )
  ON CONFLICT (date) DO UPDATE SET
    total_requests = waf_stats.total_requests + 1,
    blocked_requests = waf_stats.blocked_requests + CASE WHEN NEW.action_taken = 'blocked' THEN 1 ELSE 0 END,
    challenged_requests = waf_stats.challenged_requests + CASE WHEN NEW.action_taken = 'challenged' THEN 1 ELSE 0 END,
    allowed_requests = waf_stats.allowed_requests + CASE WHEN NEW.action_taken = 'allowed' THEN 1 ELSE 0 END;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER on_waf_log_update_stats
  AFTER INSERT ON public.waf_logs
  FOR EACH ROW
  EXECUTE FUNCTION public.update_waf_daily_stats();