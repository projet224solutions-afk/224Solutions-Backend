-- ============================================================================
-- SMS ORANGE — solde par pays (protection anti-panne)
-- Le job périodique `sms.orange-balance-check` lit le solde de CHAQUE pays activé
-- via /sms/admin/v1 et l'upsert ici. L'écran PDG lit cette table ; une alerte
-- system_alerts est levée sous le seuil (ORANGE_SMS_LOW_BALANCE_THRESHOLD).
-- Backend-only (RLS : aucune policy anon/authenticated ; écrit via service_role).
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.sms_country_balance (
  provider text NOT NULL DEFAULT 'orange',
  country text NOT NULL,                 -- ISO-2 (GN, SN, …)
  units numeric NOT NULL DEFAULT 0,      -- unités SMS restantes
  expires_at timestamptz,                -- expiration du bundle (si connue)
  sender_address text,                   -- tel:+224… (traçabilité, pas un secret)
  status text NOT NULL DEFAULT 'ok',     -- ok | low | depleted | unavailable
  checked_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (provider, country)
);

ALTER TABLE public.sms_country_balance ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS sms_country_balance_service_all ON public.sms_country_balance;
CREATE POLICY sms_country_balance_service_all ON public.sms_country_balance
  FOR ALL TO service_role USING (true) WITH CHECK (true);
