-- Créer les profils manquants pour les utilisateurs OAuth existants
-- Cette requête crée un profil pour tous les utilisateurs auth.users qui n'ont pas de profil

INSERT INTO public.profiles (id, email, full_name, first_name, last_name, custom_id, role, avatar_url, is_active, created_at, updated_at)
SELECT 
  u.id,
  u.email,
  COALESCE(u.raw_user_meta_data->>'full_name', u.raw_user_meta_data->>'name', 'Utilisateur'),
  COALESCE(u.raw_user_meta_data->>'first_name', split_part(COALESCE(u.raw_user_meta_data->>'full_name', u.raw_user_meta_data->>'name', 'Utilisateur'), ' ', 1)),
  COALESCE(u.raw_user_meta_data->>'last_name', split_part(COALESCE(u.raw_user_meta_data->>'full_name', u.raw_user_meta_data->>'name', 'Utilisateur'), ' ', 2)),
  COALESCE(u.raw_user_meta_data->>'custom_id', generate_sequential_id(
    CASE COALESCE(u.raw_user_meta_data->>'role', 'client')
      WHEN 'vendeur' THEN 'VND'
      WHEN 'client' THEN 'CLI'
      WHEN 'livreur' THEN 'DLV'
      WHEN 'taxi' THEN 'DRV'
      WHEN 'syndicat' THEN 'SYD'
      WHEN 'transitaire' THEN 'TRA'
      WHEN 'admin' THEN 'ADM'
      WHEN 'agent' THEN 'AGT'
      WHEN 'pdg' THEN 'PDG'
      ELSE 'USR'
    END
  )),
  COALESCE(u.raw_user_meta_data->>'role', 'client')::user_role,
  COALESCE(u.raw_user_meta_data->>'avatar_url', u.raw_user_meta_data->>'picture'),
  true,
  NOW(),
  NOW()
FROM auth.users u
LEFT JOIN public.profiles p ON p.id = u.id
WHERE p.id IS NULL;

-- Créer les wallets manquants pour ces utilisateurs
INSERT INTO public.wallets (user_id, balance, currency, wallet_status, created_at, updated_at)
SELECT 
  u.id,
  0,
  'GNF',
  'active',
  NOW(),
  NOW()
FROM auth.users u
LEFT JOIN public.wallets w ON w.user_id = u.id
WHERE w.id IS NULL
ON CONFLICT (user_id, currency) DO NOTHING;

-- Créer les user_ids manquants
INSERT INTO public.user_ids (user_id, custom_id, created_at)
SELECT 
  p.id,
  p.custom_id,
  NOW()
FROM public.profiles p
LEFT JOIN public.user_ids ui ON ui.user_id = p.id
WHERE ui.id IS NULL AND p.custom_id IS NOT NULL
ON CONFLICT (user_id) DO NOTHING;

-- Créer les vendors manquants pour les vendeurs
INSERT INTO public.vendors (id, user_id, business_name, email, phone, is_active, is_verified, created_at, updated_at)
SELECT 
  gen_random_uuid(),
  p.id,
  COALESCE(p.full_name, 'Entreprise'),
  p.email,
  COALESCE(p.phone, ''),
  true,
  false,
  NOW(),
  NOW()
FROM public.profiles p
LEFT JOIN public.vendors v ON v.user_id = p.id
WHERE p.role = 'vendeur' AND v.id IS NULL
ON CONFLICT (user_id) DO NOTHING;