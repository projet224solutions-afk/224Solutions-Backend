-- Ajouter le rôle admin à l'utilisateur
INSERT INTO public.user_roles (user_id, role)
VALUES ('90a84ae7-567b-4a22-b000-507451bea915', 'admin')
ON CONFLICT (user_id, role) DO NOTHING;

-- Mettre à jour le profil avec le rôle admin
UPDATE public.profiles
SET role = 'admin'
WHERE id = '90a84ae7-567b-4a22-b000-507451bea915';