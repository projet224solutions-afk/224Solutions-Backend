-- ═══════════════════════════════════════════════════════════════════════════════
-- ABONNEMENTS — Seed grilles CEDEAO + marchés cibles (décision Thierno 05/08/2026, option hybride)
-- ═══════════════════════════════════════════════════════════════════════════════
-- 10 pays ajoutés à subscription_prices (service_type='vendor', monthly), prix MARKETING ronds
-- ancrés sur la parité des grilles existantes (GN 10000/25000/50000 GNF ; ratio XOF 600/1500/3000
-- déjà en vigueur CI/SN/ML). Commissions identiques au reste : free 5% · basic 4% · pro 3% · premium 2%.
-- Idempotent (ON CONFLICT DO NOTHING sur UNIQUE country/service/plan/cycle) — n'écrase JAMAIS une
-- grille déjà ajustée par le PDG. Le PDG reste libre de modifier via son écran Country Pricing.
-- Le reste du monde (168 pays) garde le repli honnête « Tarif en GNF » jusqu'à création de sa grille.

INSERT INTO public.subscription_prices
  (country_code, service_type, plan_code, price, currency_code, commission_rate, billing_cycle, is_active)
VALUES
  -- Sierra Leone (SLE) — 1 SLE ≈ 385 GNF (référence)
  ('SL','vendor','free',       0, 'SLE', 5, 'monthly', true),
  ('SL','vendor','basic',     25, 'SLE', 4, 'monthly', true),
  ('SL','vendor','pro',       65, 'SLE', 3, 'monthly', true),
  ('SL','vendor','premium',  125, 'SLE', 2, 'monthly', true),
  -- Nigéria (NGN)
  ('NG','vendor','free',       0, 'NGN', 5, 'monthly', true),
  ('NG','vendor','basic',   1800, 'NGN', 4, 'monthly', true),
  ('NG','vendor','pro',     4500, 'NGN', 3, 'monthly', true),
  ('NG','vendor','premium', 9000, 'NGN', 2, 'monthly', true),
  -- Liberia (LRD)
  ('LR','vendor','free',       0, 'LRD', 5, 'monthly', true),
  ('LR','vendor','basic',    220, 'LRD', 4, 'monthly', true),
  ('LR','vendor','pro',      550, 'LRD', 3, 'monthly', true),
  ('LR','vendor','premium', 1100, 'LRD', 2, 'monthly', true),
  -- Gambie (GMD)
  ('GM','vendor','free',       0, 'GMD', 5, 'monthly', true),
  ('GM','vendor','basic',     80, 'GMD', 4, 'monthly', true),
  ('GM','vendor','pro',      200, 'GMD', 3, 'monthly', true),
  ('GM','vendor','premium',  400, 'GMD', 2, 'monthly', true),
  -- Ghana (GHS)
  ('GH','vendor','free',       0, 'GHS', 5, 'monthly', true),
  ('GH','vendor','basic',     18, 'GHS', 4, 'monthly', true),
  ('GH','vendor','pro',       45, 'GHS', 3, 'monthly', true),
  ('GH','vendor','premium',   90, 'GHS', 2, 'monthly', true),
  -- Zone XOF (mêmes prix que CI/SN/ML — cohérence de la zone) : Bénin, Burkina, Togo, Niger, Guinée-Bissau
  ('BJ','vendor','free',0,'XOF',5,'monthly',true),('BJ','vendor','basic',600,'XOF',4,'monthly',true),('BJ','vendor','pro',1500,'XOF',3,'monthly',true),('BJ','vendor','premium',3000,'XOF',2,'monthly',true),
  ('BF','vendor','free',0,'XOF',5,'monthly',true),('BF','vendor','basic',600,'XOF',4,'monthly',true),('BF','vendor','pro',1500,'XOF',3,'monthly',true),('BF','vendor','premium',3000,'XOF',2,'monthly',true),
  ('TG','vendor','free',0,'XOF',5,'monthly',true),('TG','vendor','basic',600,'XOF',4,'monthly',true),('TG','vendor','pro',1500,'XOF',3,'monthly',true),('TG','vendor','premium',3000,'XOF',2,'monthly',true),
  ('NE','vendor','free',0,'XOF',5,'monthly',true),('NE','vendor','basic',600,'XOF',4,'monthly',true),('NE','vendor','pro',1500,'XOF',3,'monthly',true),('NE','vendor','premium',3000,'XOF',2,'monthly',true),
  ('GW','vendor','free',0,'XOF',5,'monthly',true),('GW','vendor','basic',600,'XOF',4,'monthly',true),('GW','vendor','pro',1500,'XOF',3,'monthly',true),('GW','vendor','premium',3000,'XOF',2,'monthly',true),
  -- Compléter le basic manquant des grilles XOF existantes (CI/SN/ML n'avaient que free/pro/premium)
  ('CI','vendor','basic',600,'XOF',4,'monthly',true),
  ('SN','vendor','basic',600,'XOF',4,'monthly',true),
  ('ML','vendor','basic',600,'XOF',4,'monthly',true),
  ('ML','vendor','premium',3000,'XOF',2,'monthly',true)
ON CONFLICT (country_code, service_type, plan_code, billing_cycle) DO NOTHING;
