-- ============================================================================
-- 🌍 TOUS LES PAYS DU MONDE (référentiel countries) + devise officielle.
-- ----------------------------------------------------------------------------
-- Permet l'inscription depuis n'importe quel pays. La DEVISE est ce qui pilote le
-- prix (voir migration zones-devises) : tous les pays d'une même devise = même prix
-- (zone euro EUR, UEMOA XOF, CEMAC XAF…). Symbole dérivé pour les devises courantes.
-- payment_methods par défaut = card+wallet (les 7 pays déjà configurés gardent les leurs).
-- Rejouable (ON CONFLICT). Drapeaux rendus par CountryFlag (image ISO), flag_emoji optionnel.
-- ============================================================================

INSERT INTO public.countries (country_code, country_name, currency_code, currency_symbol, payment_methods, is_active)
SELECT v.code, v.name, v.cur,
  CASE v.cur
    WHEN 'EUR' THEN '€'  WHEN 'USD' THEN '$'  WHEN 'GBP' THEN '£'  WHEN 'JPY' THEN '¥'
    WHEN 'GNF' THEN 'FG' WHEN 'XOF' THEN 'CFA' WHEN 'XAF' THEN 'FCFA' WHEN 'MAD' THEN 'DH'
    WHEN 'NGN' THEN '₦'  WHEN 'GHS' THEN '₵'  WHEN 'INR' THEN '₹'  WHEN 'CNY' THEN '¥'
    WHEN 'BRL' THEN 'R$' WHEN 'ZAR' THEN 'R'  WHEN 'KES' THEN 'KSh' WHEN 'EGP' THEN 'E£'
    WHEN 'AED' THEN 'د.إ' WHEN 'SAR' THEN '﷼' WHEN 'CAD' THEN 'C$' WHEN 'AUD' THEN 'A$'
    WHEN 'CHF' THEN 'CHF' WHEN 'TRY' THEN '₺' WHEN 'RUB' THEN '₽' WHEN 'KRW' THEN '₩'
    ELSE v.cur
  END,
  ARRAY['card','wallet'], true
FROM (VALUES
  -- ── Zone EURO (EUR) : MÊME prix garanti ──────────────────────────────────
  ('AT','Autriche','EUR'),('BE','Belgique','EUR'),('HR','Croatie','EUR'),('CY','Chypre','EUR'),
  ('EE','Estonie','EUR'),('FI','Finlande','EUR'),('FR','France','EUR'),('DE','Allemagne','EUR'),
  ('GR','Grèce','EUR'),('IE','Irlande','EUR'),('IT','Italie','EUR'),('LV','Lettonie','EUR'),
  ('LT','Lituanie','EUR'),('LU','Luxembourg','EUR'),('MT','Malte','EUR'),('NL','Pays-Bas','EUR'),
  ('PT','Portugal','EUR'),('SK','Slovaquie','EUR'),('SI','Slovénie','EUR'),('ES','Espagne','EUR'),
  ('AD','Andorre','EUR'),('MC','Monaco','EUR'),('ME','Monténégro','EUR'),('SM','Saint-Marin','EUR'),
  ('VA','Vatican','EUR'),('XK','Kosovo','EUR'),
  -- ── UEMOA (XOF) ──────────────────────────────────────────────────────────
  ('BJ','Bénin','XOF'),('BF','Burkina Faso','XOF'),('CI','Côte d''Ivoire','XOF'),('GW','Guinée-Bissau','XOF'),
  ('ML','Mali','XOF'),('NE','Niger','XOF'),('SN','Sénégal','XOF'),('TG','Togo','XOF'),
  -- ── CEMAC (XAF) ──────────────────────────────────────────────────────────
  ('CM','Cameroun','XAF'),('CF','Centrafrique','XAF'),('TD','Tchad','XAF'),('CG','Congo','XAF'),
  ('GQ','Guinée équatoriale','XAF'),('GA','Gabon','XAF'),
  -- ── Afrique (autres devises) ─────────────────────────────────────────────
  ('GN','Guinée','GNF'),('MA','Maroc','MAD'),('DZ','Algérie','DZD'),('TN','Tunisie','TND'),
  ('LY','Libye','LYD'),('EG','Égypte','EGP'),('MR','Mauritanie','MRU'),('NG','Nigéria','NGN'),
  ('GH','Ghana','GHS'),('LR','Liberia','LRD'),('SL','Sierra Leone','SLE'),('GM','Gambie','GMD'),
  ('CV','Cap-Vert','CVE'),('ST','Sao Tomé','STN'),('KE','Kenya','KES'),('TZ','Tanzanie','TZS'),
  ('UG','Ouganda','UGX'),('RW','Rwanda','RWF'),('BI','Burundi','BIF'),('ET','Éthiopie','ETB'),
  ('SO','Somalie','SOS'),('DJ','Djibouti','DJF'),('ER','Érythrée','ERN'),('SS','Soudan du Sud','SSP'),
  ('SD','Soudan','SDG'),('CD','RD Congo','CDF'),('AO','Angola','AOA'),('ZM','Zambie','ZMW'),
  ('ZW','Zimbabwe','ZWL'),('MW','Malawi','MWK'),('MZ','Mozambique','MZN'),('BW','Botswana','BWP'),
  ('NA','Namibie','NAD'),('ZA','Afrique du Sud','ZAR'),('LS','Lesotho','LSL'),('SZ','Eswatini','SZL'),
  ('MG','Madagascar','MGA'),('MU','Maurice','MUR'),('SC','Seychelles','SCR'),('KM','Comores','KMF'),
  -- ── Amériques ────────────────────────────────────────────────────────────
  ('US','États-Unis','USD'),('CA','Canada','CAD'),('MX','Mexique','MXN'),('BR','Brésil','BRL'),
  ('AR','Argentine','ARS'),('CL','Chili','CLP'),('CO','Colombie','COP'),('PE','Pérou','PEN'),
  ('VE','Venezuela','VES'),('EC','Équateur','USD'),('BO','Bolivie','BOB'),('PY','Paraguay','PYG'),
  ('UY','Uruguay','UYU'),('GT','Guatemala','GTQ'),('HN','Honduras','HNL'),('SV','Salvador','USD'),
  ('NI','Nicaragua','NIO'),('CR','Costa Rica','CRC'),('PA','Panama','USD'),('DO','Rép. dominicaine','DOP'),
  ('CU','Cuba','CUP'),('HT','Haïti','HTG'),('JM','Jamaïque','JMD'),('TT','Trinité-et-Tobago','TTD'),
  ('BS','Bahamas','BSD'),('BB','Barbade','BBD'),('BZ','Belize','BZD'),('GY','Guyana','GYD'),
  ('SR','Suriname','SRD'),
  -- ── Europe (hors zone euro) ──────────────────────────────────────────────
  ('GB','Royaume-Uni','GBP'),('CH','Suisse','CHF'),('NO','Norvège','NOK'),('SE','Suède','SEK'),
  ('DK','Danemark','DKK'),('IS','Islande','ISK'),('PL','Pologne','PLN'),('CZ','Tchéquie','CZK'),
  ('HU','Hongrie','HUF'),('RO','Roumanie','RON'),('BG','Bulgarie','BGN'),('RS','Serbie','RSD'),
  ('BA','Bosnie-Herzégovine','BAM'),('MK','Macédoine du Nord','MKD'),('AL','Albanie','ALL'),
  ('UA','Ukraine','UAH'),('BY','Biélorussie','BYN'),('MD','Moldavie','MDL'),('RU','Russie','RUB'),
  ('TR','Turquie','TRY'),('GE','Géorgie','GEL'),('AM','Arménie','AMD'),('AZ','Azerbaïdjan','AZN'),
  ('LI','Liechtenstein','CHF'),
  -- ── Moyen-Orient ─────────────────────────────────────────────────────────
  ('SA','Arabie saoudite','SAR'),('AE','Émirats arabes unis','AED'),('QA','Qatar','QAR'),
  ('KW','Koweït','KWD'),('BH','Bahreïn','BHD'),('OM','Oman','OMR'),('JO','Jordanie','JOD'),
  ('LB','Liban','LBP'),('IL','Israël','ILS'),('PS','Palestine','ILS'),('IQ','Irak','IQD'),
  ('IR','Iran','IRR'),('SY','Syrie','SYP'),('YE','Yémen','YER'),
  -- ── Asie ─────────────────────────────────────────────────────────────────
  ('CN','Chine','CNY'),('JP','Japon','JPY'),('KR','Corée du Sud','KRW'),('IN','Inde','INR'),
  ('PK','Pakistan','PKR'),('BD','Bangladesh','BDT'),('LK','Sri Lanka','LKR'),('NP','Népal','NPR'),
  ('AF','Afghanistan','AFN'),('KZ','Kazakhstan','KZT'),('UZ','Ouzbékistan','UZS'),('TM','Turkménistan','TMT'),
  ('KG','Kirghizistan','KGS'),('TJ','Tadjikistan','TJS'),('MN','Mongolie','MNT'),('TH','Thaïlande','THB'),
  ('VN','Vietnam','VND'),('ID','Indonésie','IDR'),('MY','Malaisie','MYR'),('SG','Singapour','SGD'),
  ('PH','Philippines','PHP'),('MM','Birmanie','MMK'),('KH','Cambodge','KHR'),('LA','Laos','LAK'),
  ('BN','Brunei','BND'),('BT','Bhoutan','BTN'),('MV','Maldives','MVR'),('TW','Taïwan','TWD'),
  ('HK','Hong Kong','HKD'),('MO','Macao','MOP'),
  -- ── Océanie ──────────────────────────────────────────────────────────────
  ('AU','Australie','AUD'),('NZ','Nouvelle-Zélande','NZD'),('FJ','Fidji','FJD'),('PG','Papouasie-N.-Guinée','PGK'),
  ('SB','Îles Salomon','SBD'),('VU','Vanuatu','VUV'),('WS','Samoa','WST'),('TO','Tonga','TOP')
) AS v(code,name,cur)
ON CONFLICT (country_code) DO UPDATE
  SET country_name   = EXCLUDED.country_name,
      currency_code  = EXCLUDED.currency_code,
      currency_symbol = EXCLUDED.currency_symbol,
      updated_at = now();
  -- NB : payment_methods et is_active des pays déjà configurés sont PRÉSERVÉS (non écrasés).

SELECT count(*) AS total_pays, count(*) FILTER (WHERE is_active) AS pays_actifs,
       count(DISTINCT currency_code) AS devises
FROM public.countries;
