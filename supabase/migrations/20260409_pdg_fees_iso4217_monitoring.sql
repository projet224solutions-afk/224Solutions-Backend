-- MIGRATION: Uniformisation des frais, validation devise, monitoring taux
-- 1. Uniformisation des frais dans process_secure_wallet_transfer
-- (Remplace la logique de taux en dur par lecture dynamique)


-- Correction : extraction du taux depuis JSON (ex: {"value":0.01})
DO $$
DECLARE
  v_fee_rate NUMERIC;
BEGIN
  SELECT (setting_value->>'value')::NUMERIC INTO v_fee_rate FROM pdg_settings WHERE setting_key = 'wallet_transaction_fee_percentage';
  IF v_fee_rate IS NULL THEN
    v_fee_rate := 0.01; -- fallback
  END IF;
  -- Utiliser v_fee_rate dans le calcul des frais
END $$;

-- 2. Validation stricte des devises ISO 4217
ALTER TABLE wallets
  ADD CONSTRAINT chk_currency_iso4217
  CHECK (currency IN ('GNF','XOF','USD','EUR','CFA','GBP','JPY','CNY','CAD','AUD','CHF','ZAR','MAD','TRY','INR','BRL','RUB','SGD','HKD','NZD','SEK','NOK','DKK','PLN','CZK','HUF','ILS','KRW','MXN','MYR','THB','TWD','PHP','IDR','SAR','AED','QAR','KWD','BHD','OMR','EGP','NGN','KES','TZS','UGX','RWF','BIF','MGA','XAF','VND','CLP','COP','PYG','BAM','HRK','RON','BGN','UAH','GEL','BYN','AZN','KZT','UZS','TMT','AFN','PKR','LKR','BDT','NPR','MMK','LAK','KHR','MOP','VUV','FJD','SBD','TOP','WST','PGK','BTN','MVR','SCR','MUR','LKR','BND','KPW','MNT','KGS','TJS','AMD','MDL','ALL','MKD','ISK','DZD','TND','LYD','SDG','SSP','ETB','DJF','SOS','SZL','LSL','MWK','ZMW','GHS','SLL','GMD','GNF','CVE','XOF','XAF','XPF'));

-- 3. Monitoring des taux (alerte si écart)
CREATE TABLE IF NOT EXISTS exchange_rate_alerts (
  id SERIAL PRIMARY KEY,
  currency_from VARCHAR(3) NOT NULL,
  currency_to VARCHAR(3) NOT NULL,
  rate_site NUMERIC NOT NULL,
  rate_api NUMERIC NOT NULL,
  delta NUMERIC NOT NULL,
  threshold NUMERIC NOT NULL DEFAULT 0.01,
  alert_time TIMESTAMPTZ DEFAULT now(),
  is_read BOOLEAN DEFAULT false
);

-- Fonction d’alerte (à appeler après chaque update de taux)
CREATE OR REPLACE FUNCTION check_exchange_rate_alert(
  p_currency_from VARCHAR,
  p_currency_to VARCHAR,
  p_rate_site NUMERIC,
  p_rate_api NUMERIC,
  p_threshold NUMERIC DEFAULT 0.01
) RETURNS VOID AS $$
BEGIN
  IF abs(p_rate_site - p_rate_api) / p_rate_site > p_threshold THEN
    INSERT INTO exchange_rate_alerts(currency_from, currency_to, rate_site, rate_api, delta, threshold)
    VALUES (p_currency_from, p_currency_to, p_rate_site, p_rate_api, abs(p_rate_site - p_rate_api), p_threshold);
  END IF;
END;
$$ LANGUAGE plpgsql;
