
-- Table de configuration de la marge
CREATE TABLE IF NOT EXISTS public.margin_config (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  config_key TEXT NOT NULL UNIQUE,
  config_value NUMERIC NOT NULL,
  description TEXT,
  updated_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE public.margin_config ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone can view margin_config" ON public.margin_config FOR SELECT USING (true);
CREATE POLICY "Auth can update margin_config" ON public.margin_config FOR UPDATE TO authenticated USING (true);
CREATE POLICY "Auth can insert margin_config" ON public.margin_config FOR INSERT TO authenticated WITH CHECK (true);

INSERT INTO public.margin_config (config_key, config_value, description)
VALUES ('default_margin', 0.03, 'Marge par défaut de 3% appliquée sur les taux officiels')
ON CONFLICT (config_key) DO NOTHING;

-- Ajouter colonnes manquantes à currency_exchange_rates
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='currency_exchange_rates' AND column_name='rate_usd') THEN
    ALTER TABLE public.currency_exchange_rates ADD COLUMN rate_usd NUMERIC;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='currency_exchange_rates' AND column_name='rate_eur') THEN
    ALTER TABLE public.currency_exchange_rates ADD COLUMN rate_eur NUMERIC;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='currency_exchange_rates' AND column_name='margin') THEN
    ALTER TABLE public.currency_exchange_rates ADD COLUMN margin NUMERIC DEFAULT 0.03;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='currency_exchange_rates' AND column_name='final_rate_usd') THEN
    ALTER TABLE public.currency_exchange_rates ADD COLUMN final_rate_usd NUMERIC;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='currency_exchange_rates' AND column_name='final_rate_eur') THEN
    ALTER TABLE public.currency_exchange_rates ADD COLUMN final_rate_eur NUMERIC;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='currency_exchange_rates' AND column_name='source_url') THEN
    ALTER TABLE public.currency_exchange_rates ADD COLUMN source_url TEXT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='currency_exchange_rates' AND column_name='retrieved_at') THEN
    ALTER TABLE public.currency_exchange_rates ADD COLUMN retrieved_at TIMESTAMPTZ DEFAULT now();
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='currency_exchange_rates' AND column_name='status') THEN
    ALTER TABLE public.currency_exchange_rates ADD COLUMN status TEXT DEFAULT 'OK';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='currency_exchange_rates' AND column_name='is_active') THEN
    ALTER TABLE public.currency_exchange_rates ADD COLUMN is_active BOOLEAN DEFAULT true;
  END IF;
END $$;

-- Table de logs de conversion
CREATE TABLE IF NOT EXISTS public.conversion_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id TEXT,
  user_id UUID REFERENCES auth.users(id),
  initial_amount NUMERIC NOT NULL,
  initial_currency TEXT NOT NULL,
  final_amount NUMERIC NOT NULL,
  final_currency TEXT NOT NULL,
  rate_applied NUMERIC NOT NULL,
  margin NUMERIC NOT NULL DEFAULT 0.03,
  conversion_type TEXT DEFAULT 'deposit',
  conversion_date DATE DEFAULT CURRENT_DATE,
  conversion_time TIME DEFAULT CURRENT_TIME,
  created_at TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE public.conversion_logs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can view own conversion_logs" ON public.conversion_logs FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "System can insert conversion_logs" ON public.conversion_logs FOR INSERT TO authenticated WITH CHECK (true);
CREATE INDEX IF NOT EXISTS idx_conversion_logs_user ON public.conversion_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_conversion_logs_date ON public.conversion_logs(conversion_date DESC);

-- Table historique des collectes
CREATE TABLE IF NOT EXISTS public.fx_collection_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  currency_code TEXT NOT NULL,
  rate_usd NUMERIC,
  rate_eur NUMERIC,
  source TEXT NOT NULL,
  source_url TEXT,
  status TEXT NOT NULL DEFAULT 'OK',
  error_message TEXT,
  collected_at TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE public.fx_collection_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone can view fx_collection_log" ON public.fx_collection_log FOR SELECT USING (true);
CREATE POLICY "System insert fx_collection_log" ON public.fx_collection_log FOR INSERT WITH CHECK (true);
CREATE INDEX IF NOT EXISTS idx_fx_collection_log_currency ON public.fx_collection_log(currency_code, collected_at DESC);

-- Fonction de conversion avec marge
CREATE OR REPLACE FUNCTION public.convert_with_margin(
  p_amount NUMERIC,
  p_from_currency TEXT,
  p_to_currency TEXT,
  p_user_id UUID DEFAULT NULL,
  p_transaction_id TEXT DEFAULT NULL,
  p_conversion_type TEXT DEFAULT 'deposit'
) RETURNS TABLE(converted_amount NUMERIC, rate_used NUMERIC, margin_applied NUMERIC) 
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_rate NUMERIC;
  v_margin NUMERIC;
  v_final_amount NUMERIC;
  v_r1 NUMERIC;
  v_r2 NUMERIC;
BEGIN
  IF UPPER(p_from_currency) = UPPER(p_to_currency) THEN
    converted_amount := p_amount;
    rate_used := 1;
    margin_applied := 0;
    RETURN NEXT;
    RETURN;
  END IF;

  SELECT config_value INTO v_margin FROM margin_config WHERE config_key = 'default_margin';
  IF v_margin IS NULL THEN v_margin := 0.03; END IF;

  SELECT rate INTO v_rate FROM currency_exchange_rates
  WHERE from_currency = UPPER(p_from_currency) AND to_currency = UPPER(p_to_currency) AND is_active = true
  ORDER BY effective_date DESC, updated_at DESC LIMIT 1;

  IF v_rate IS NULL THEN
    SELECT 1.0 / rate INTO v_rate FROM currency_exchange_rates
    WHERE from_currency = UPPER(p_to_currency) AND to_currency = UPPER(p_from_currency) AND is_active = true AND rate > 0
    ORDER BY effective_date DESC, updated_at DESC LIMIT 1;
  END IF;

  IF v_rate IS NULL THEN
    SELECT rate INTO v_r1 FROM currency_exchange_rates
    WHERE from_currency = UPPER(p_from_currency) AND to_currency = 'USD' AND is_active = true
    ORDER BY effective_date DESC LIMIT 1;
    SELECT rate INTO v_r2 FROM currency_exchange_rates
    WHERE from_currency = 'USD' AND to_currency = UPPER(p_to_currency) AND is_active = true
    ORDER BY effective_date DESC LIMIT 1;
    IF v_r1 IS NOT NULL AND v_r2 IS NOT NULL THEN
      v_rate := v_r1 * v_r2;
    END IF;
  END IF;

  IF v_rate IS NULL THEN
    RAISE EXCEPTION 'Taux de change introuvable: % -> %', p_from_currency, p_to_currency;
  END IF;

  v_final_amount := p_amount * v_rate * (1 + v_margin);

  IF p_user_id IS NOT NULL THEN
    INSERT INTO conversion_logs (transaction_id, user_id, initial_amount, initial_currency, final_amount, final_currency, rate_applied, margin, conversion_type)
    VALUES (p_transaction_id, p_user_id, p_amount, UPPER(p_from_currency), v_final_amount, UPPER(p_to_currency), v_rate, v_margin, p_conversion_type);
  END IF;

  converted_amount := v_final_amount;
  rate_used := v_rate;
  margin_applied := v_margin;
  RETURN NEXT;
END;
$$;
