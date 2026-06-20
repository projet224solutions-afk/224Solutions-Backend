-- ===========================================
-- RLS POLICIES WALLET - CORRECTION SYNTAXE
-- ===========================================

-- Activer RLS
ALTER TABLE public.wallet_payment_methods ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.currencies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exchange_rates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallet_fees ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallet_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallet_suspicious_activities ENABLE ROW LEVEL SECURITY;

-- wallet_payment_methods
CREATE POLICY "payment_methods_select" ON public.wallet_payment_methods FOR SELECT
USING (wallet_id IN (SELECT id FROM public.wallets WHERE user_id = auth.uid()));

CREATE POLICY "payment_methods_insert" ON public.wallet_payment_methods FOR INSERT
WITH CHECK (wallet_id IN (SELECT id FROM public.wallets WHERE user_id = auth.uid()));

CREATE POLICY "payment_methods_update" ON public.wallet_payment_methods FOR UPDATE
USING (wallet_id IN (SELECT id FROM public.wallets WHERE user_id = auth.uid()));

CREATE POLICY "payment_methods_delete" ON public.wallet_payment_methods FOR DELETE
USING (wallet_id IN (SELECT id FROM public.wallets WHERE user_id = auth.uid()));

CREATE POLICY "payment_methods_service" ON public.wallet_payment_methods FOR ALL
USING (auth.role() = 'service_role')
WITH CHECK (auth.role() = 'service_role');

-- currencies
CREATE POLICY "currencies_select" ON public.currencies FOR SELECT
USING (is_active = true OR auth.role() = 'service_role');

CREATE POLICY "currencies_admin" ON public.currencies FOR INSERT
WITH CHECK (auth.role() = 'service_role');

CREATE POLICY "currencies_admin_update" ON public.currencies FOR UPDATE
USING (auth.role() = 'service_role');

CREATE POLICY "currencies_admin_delete" ON public.currencies FOR DELETE
USING (auth.role() = 'service_role');

-- exchange_rates
CREATE POLICY "rates_select" ON public.exchange_rates FOR SELECT
USING (is_active = true OR auth.role() = 'service_role');

CREATE POLICY "rates_service" ON public.exchange_rates FOR ALL
USING (auth.role() = 'service_role')
WITH CHECK (auth.role() = 'service_role');

-- wallet_fees
CREATE POLICY "fees_select" ON public.wallet_fees FOR SELECT
USING (is_active = true OR auth.role() = 'service_role');

CREATE POLICY "fees_service" ON public.wallet_fees FOR ALL
USING (auth.role() = 'service_role')
WITH CHECK (auth.role() = 'service_role');

-- wallet_logs
CREATE POLICY "logs_select" ON public.wallet_logs FOR SELECT
USING (user_id = auth.uid() OR auth.role() = 'service_role');

CREATE POLICY "logs_service" ON public.wallet_logs FOR ALL
USING (auth.role() = 'service_role')
WITH CHECK (auth.role() = 'service_role');

-- wallet_suspicious_activities  
CREATE POLICY "suspicious_service" ON public.wallet_suspicious_activities FOR ALL
USING (auth.role() = 'service_role')
WITH CHECK (auth.role() = 'service_role');