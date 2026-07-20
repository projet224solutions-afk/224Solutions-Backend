-- ============================================================================
-- FILET DB GÉO — le pays est déduit du TÉLÉPHONE à l'inscription (côté infra),
-- indépendamment du frontend. countries.phone_code + iso_from_phone() +
-- handle_new_user patché : si aucun pays en métadonnées, on le déduit de l'indicatif
-- du numéro (déjà transmis en +XXX), puis la devise du wallet suit le pays.
-- ============================================================================

ALTER TABLE public.countries ADD COLUMN IF NOT EXISTS phone_code text;

UPDATE public.countries c SET phone_code = m.code
FROM (VALUES ('GN','224'),('SN','221'),('ML','223'),('CI','225'),('BF','226'),('NE','227'),('TG','228'),('BJ','229'),('MR','222'),('GM','220'),('GW','245'),('CV','238'),('LR','231'),('SL','232'),('GH','233'),('NG','234'),('TD','235'),('CF','236'),('CM','237'),('CG','242'),('CD','243'),('GA','241'),('GQ','240'),('ST','239'),('AO','244'),('MA','212'),('DZ','213'),('TN','216'),('LY','218'),('EG','20'),('SD','249'),('SS','211'),('ET','251'),('KE','254'),('UG','256'),('TZ','255'),('RW','250'),('BI','257'),('DJ','253'),('SO','252'),('ER','291'),('ZA','27'),('ZM','260'),('ZW','263'),('MW','265'),('MZ','258'),('MG','261'),('BW','267'),('NA','264'),('SZ','268'),('LS','266'),('KM','269'),('SC','248'),('MU','230'),('FR','33'),('DE','49'),('GB','44'),('BE','32'),('ES','34'),('PT','351'),('IT','39'),('NL','31'),('CH','41'),('LU','352'),('IE','353'),('AT','43'),('SE','46'),('NO','47'),('DK','45'),('FI','358'),('PL','48'),('GR','30'),('RO','40'),('RU','7'),('TR','90'),('UA','380'),('US','1'),('BR','55'),('MX','52'),('AR','54'),('CO','57'),('CL','56'),('PE','51'),('CN','86'),('IN','91'),('JP','81'),('KR','82'),('ID','62'),('PK','92'),('BD','880'),('PH','63'),('VN','84'),('TH','66'),('MY','60'),('SG','65'),('SA','966'),('AE','971'),('QA','974'),('KW','965'),('BH','973'),('OM','968'),('JO','962'),('LB','961'),('IL','972'),('IQ','964'),('IR','98'),('YE','967'),('SY','963'),('AU','61'),('NZ','64')) AS m(iso, code)
WHERE c.country_code = m.iso;

-- Indicatif → ISO-2 (plus long préfixe qui matche les chiffres du numéro).
CREATE OR REPLACE FUNCTION public.iso_from_phone(p_phone text)
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT c.country_code
  FROM public.countries c
  WHERE c.phone_code IS NOT NULL AND c.phone_code <> ''
    AND regexp_replace(COALESCE(p_phone, ''), '[^0-9]', '', 'g') LIKE (c.phone_code || '%')
  ORDER BY length(c.phone_code) DESC, c.country_code
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  user_role_value      user_role;
  user_role_text       TEXT;
  raw_role             TEXT;
  account_type_raw     TEXT;
  generated_public_id  TEXT;
  v_detected_country   TEXT;
  v_detected_currency  TEXT;
  v_wallet_currency    TEXT;
BEGIN
  raw_role         := (NEW.raw_user_meta_data::jsonb)->>'role';
  account_type_raw := (NEW.raw_user_meta_data::jsonb)->>'account_type';

  IF raw_role IS NOT NULL AND raw_role != '' THEN
    user_role_text := raw_role;
  ELSIF account_type_raw IS NOT NULL AND account_type_raw != '' THEN
    CASE account_type_raw
      WHEN 'marchand'    THEN user_role_text := 'vendeur';
      WHEN 'merchant'    THEN user_role_text := 'vendeur';
      WHEN 'livreur'     THEN user_role_text := 'livreur';
      WHEN 'driver'      THEN user_role_text := 'livreur';
      WHEN 'taxi_moto'   THEN user_role_text := 'taxi';
      WHEN 'taxi-moto'   THEN user_role_text := 'taxi';
      WHEN 'transitaire' THEN user_role_text := 'transitaire';
      WHEN 'prestataire' THEN user_role_text := 'prestataire';
      WHEN 'service'     THEN user_role_text := 'prestataire';
      WHEN 'client'      THEN user_role_text := 'client';
      ELSE                    user_role_text := 'client';
    END CASE;
  ELSE
    user_role_text := 'client';
  END IF;

  -- Validation explicite: evite conversion silencieuse de roles inconnus en 'client'
  IF user_role_text NOT IN (
    'client','vendeur','livreur','taxi','driver','syndicat','bureau',
    'transitaire','prestataire','pdg','admin','ceo','agent','vendor_agent',
    'actionnaire'
  ) THEN
    RAISE LOG '[handle_new_user] Role inconnu % pour user %, remplace par client', user_role_text, NEW.id;
    user_role_text := 'client';
  END IF;

  BEGIN
    user_role_value := user_role_text::user_role;
  EXCEPTION WHEN OTHERS THEN
    RAISE LOG '[handle_new_user] Erreur cast role % pour user %: %. Fallback client.', user_role_text, NEW.id, SQLERRM;
    user_role_text  := 'client';
    user_role_value := 'client'::user_role;
  END;

  generated_public_id := public.generate_unique_public_id(user_role_text);

  v_detected_country := NULLIF(
    UPPER(TRIM(COALESCE((NEW.raw_user_meta_data::jsonb)->>'detected_country', ''))), ''
  );
  v_detected_currency := NULLIF(
    UPPER(TRIM(COALESCE((NEW.raw_user_meta_data::jsonb)->>'detected_currency', ''))), ''
  );

  IF v_detected_country IS NOT NULL AND LENGTH(v_detected_country) != 2 THEN
    v_detected_country := NULL;
  END IF;
  IF v_detected_currency IS NOT NULL AND LENGTH(v_detected_currency) != 3 THEN
    v_detected_currency := NULL;
  END IF;

  -- FILET : si le pays n'est pas fourni en métadonnées, le déduire de l'indicatif
  -- du téléphone (transmis avec l'indicatif international, ex. « +221 … »).
  IF v_detected_country IS NULL THEN
    v_detected_country := public.iso_from_phone(
      COALESCE((NEW.raw_user_meta_data::jsonb)->>'phone', NEW.phone));
  END IF;

  INSERT INTO public.profiles (
    id, email, first_name, last_name, role, phone,
    public_id, country,
    detected_country, detected_currency, is_active, created_at, updated_at
  )
  VALUES (
    NEW.id,
    LOWER(TRIM(COALESCE(NEW.email, ''))),
    COALESCE(
      (NEW.raw_user_meta_data::jsonb)->>'first_name',
      SPLIT_PART(COALESCE((NEW.raw_user_meta_data::jsonb)->>'full_name', ''), ' ', 1),
      ''
    ),
    COALESCE(
      (NEW.raw_user_meta_data::jsonb)->>'last_name',
      NULLIF(TRIM(SUBSTRING(COALESCE((NEW.raw_user_meta_data::jsonb)->>'full_name', '') FROM POSITION(' ' IN COALESCE((NEW.raw_user_meta_data::jsonb)->>'full_name', '')))), ''),
      ''
    ),
    user_role_value,
    COALESCE((NEW.raw_user_meta_data::jsonb)->>'phone', NULL),
    generated_public_id,
    v_detected_country,
    v_detected_country,
    v_detected_currency,
    true,
    NOW(),
    NOW()
  )
  ON CONFLICT (id) DO NOTHING;

  v_wallet_currency := COALESCE(v_detected_currency, public.get_currency_for_country(v_detected_country), 'GNF');

  -- CORRECTIF : `wallets` n'a pas de colonne is_active → on l'enlève (wallet_status
  -- prend sa valeur par défaut). Sans ça, tout le trigger échouait silencieusement.
  INSERT INTO public.wallets (user_id, balance, currency)
  VALUES (NEW.id, 0, v_wallet_currency)
  ON CONFLICT (user_id) DO NOTHING;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE LOG 'Error in handle_new_user for user %: %', NEW.id, SQLERRM;
  RETURN NEW;
END;
$function$
;
