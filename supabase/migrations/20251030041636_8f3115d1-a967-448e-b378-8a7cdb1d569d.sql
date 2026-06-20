-- Créer automatiquement des entrées vendors pour les profiles avec role vendeur qui n'en ont pas
DO $$
DECLARE
  profile_record RECORD;
  new_vendor_code TEXT;
BEGIN
  FOR profile_record IN 
    SELECT p.id, p.email, p.first_name, p.last_name, p.phone
    FROM profiles p
    LEFT JOIN vendors v ON v.user_id = p.id
    WHERE p.role = 'vendeur' AND v.id IS NULL
  LOOP
    -- Générer le code vendor
    new_vendor_code := generate_vendor_code();
    
    -- Créer le vendor
    INSERT INTO vendors (
      user_id,
      business_name,
      email,
      phone,
      vendor_code,
      is_active,
      is_verified
    ) VALUES (
      profile_record.id,
      COALESCE(profile_record.first_name || ' ' || profile_record.last_name, profile_record.email),
      profile_record.email,
      profile_record.phone,
      new_vendor_code,
      true,
      false
    );
    
    -- Mettre à jour le custom_id du profile
    UPDATE profiles 
    SET custom_id = new_vendor_code
    WHERE id = profile_record.id;
    
    RAISE NOTICE 'Créé vendor % pour %', new_vendor_code, profile_record.email;
  END LOOP;
END $$;