-- pdg_financial_alerts currently enforces a hard-coded whitelist of alert_type
-- values that no longer matches the runtime writers. This breaks privileged role
-- promotions and FX/security alert creation. Replace the brittle whitelist with
-- a format/non-empty constraint so new alert types remain forward-compatible.

ALTER TABLE public.pdg_financial_alerts
DROP CONSTRAINT IF EXISTS pdg_financial_alerts_alert_type_check;

ALTER TABLE public.pdg_financial_alerts
ADD CONSTRAINT pdg_financial_alerts_alert_type_check
CHECK (
  btrim(alert_type) <> ''
  AND alert_type ~ '^[A-Za-z0-9_:-]+$'
);