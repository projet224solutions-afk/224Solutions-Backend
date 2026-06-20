-- Créer un compte admin de test avec un email et mot de passe simple
-- Note: Ce compte sera créé manuellement via l'interface Supabase Auth
-- Voici les étapes que l'utilisateur doit suivre:

-- 1. Aller sur https://supabase.com/dashboard/project/uakkxaibujzxdiqzpnpr/auth/users
-- 2. Cliquer sur "Add user" -> "Create new user"
-- 3. Email: admin@224solution.net
-- 4. Password: Admin123!
-- 5. Confirmer l'email automatiquement

-- Puis ajouter le rôle admin pour ce compte
INSERT INTO public.user_roles (user_id, role)
SELECT id, 'admin'::user_role
FROM auth.users
WHERE email = 'admin@224solution.net'
ON CONFLICT (user_id, role) DO NOTHING;

-- Mettre à jour le profil
UPDATE public.profiles
SET role = 'admin',
    first_name = 'Admin',
    last_name = '224Solutions'
WHERE id IN (SELECT id FROM auth.users WHERE email = 'admin@224solution.net');