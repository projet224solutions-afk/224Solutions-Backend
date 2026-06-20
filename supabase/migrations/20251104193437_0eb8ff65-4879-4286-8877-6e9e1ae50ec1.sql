-- Créer une fonction pour créer automatiquement un profil driver
CREATE OR REPLACE FUNCTION public.create_driver_profile()
RETURNS TRIGGER AS $$
BEGIN
  -- Vérifier si l'utilisateur a le rôle "livreur"
  IF NEW.raw_user_meta_data->>'role' = 'livreur' THEN
    -- Créer un profil driver
    INSERT INTO public.drivers (
      user_id,
      full_name,
      phone_number,
      email,
      status,
      is_online,
      is_verified,
      rating,
      earnings_total,
      commission_rate,
      total_deliveries,
      license_number,
      vehicle_type
    ) VALUES (
      NEW.id,
      COALESCE(NEW.raw_user_meta_data->>'first_name', '') || ' ' || COALESCE(NEW.raw_user_meta_data->>'last_name', ''),
      COALESCE(NEW.raw_user_meta_data->>'phone', NEW.phone, ''),
      NEW.email,
      'offline',
      false,
      false,
      0,
      0,
      1.5, -- 1.5% de commission par défaut
      0,
      'LIC-' || SUBSTRING(NEW.id::text, 1, 8), -- Générer un numéro de licence à partir de l'ID
      'moto'::vehicle_type -- Type par défaut pour livreurs
    )
    ON CONFLICT (user_id) DO NOTHING;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Créer le trigger sur auth.users
DROP TRIGGER IF EXISTS on_auth_user_created_driver ON auth.users;
CREATE TRIGGER on_auth_user_created_driver
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.create_driver_profile();

-- Créer les profils manquants pour tous les utilisateurs livreurs existants
INSERT INTO public.drivers (
  user_id,
  full_name,
  phone_number,
  email,
  status,
  is_online,
  is_verified,
  rating,
  earnings_total,
  commission_rate,
  total_deliveries,
  license_number,
  vehicle_type
)
SELECT 
  id,
  COALESCE(raw_user_meta_data->>'first_name', '') || ' ' || COALESCE(raw_user_meta_data->>'last_name', ''),
  COALESCE(raw_user_meta_data->>'phone', phone, ''),
  email,
  'offline',
  false,
  false,
  0,
  0,
  1.5,
  0,
  'LIC-' || SUBSTRING(id::text, 1, 8),
  'moto'::vehicle_type
FROM auth.users
WHERE raw_user_meta_data->>'role' = 'livreur'
  AND NOT EXISTS (SELECT 1 FROM public.drivers WHERE drivers.user_id = auth.users.id)
ON CONFLICT (user_id) DO NOTHING;

-- Ajouter un commentaire pour expliquer la fonction
COMMENT ON FUNCTION public.create_driver_profile() IS 'Crée automatiquement un profil driver quand un utilisateur avec le rôle "livreur" est créé';