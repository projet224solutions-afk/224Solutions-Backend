-- =========================================
-- SCRIPT DE DIAGNOSTIC BASE DE DONNÉES
-- Exécutez dans Supabase Dashboard > SQL Editor
-- =========================================

-- 1. Vérifier la structure de la table profiles
SELECT 
    column_name, 
    data_type, 
    is_nullable,
    column_default
FROM information_schema.columns 
WHERE table_schema = 'public' 
AND table_name = 'profiles'
ORDER BY ordinal_position;

-- 2. Vérifier si RLS est activé sur profiles
SELECT 
    schemaname,
    tablename,
    rowsecurity
FROM pg_tables 
WHERE schemaname = 'public' 
AND tablename = 'profiles';

-- 3. Lister toutes les politiques RLS sur profiles
SELECT 
    policyname,
    cmd AS operation,
    permissive,
    qual AS using_expression,
    with_check AS check_expression
FROM pg_policies 
WHERE schemaname = 'public' 
AND tablename = 'profiles'
ORDER BY policyname;

-- 4. Vérifier les buckets de stockage
SELECT 
    id,
    name,
    public,
    file_size_limit,
    created_at
FROM storage.buckets
ORDER BY created_at DESC
LIMIT 10;

-- 5. Lister les politiques RLS sur storage.objects
SELECT 
    policyname,
    cmd AS operation,
    permissive
FROM pg_policies 
WHERE schemaname = 'storage' 
AND tablename = 'objects'
ORDER BY policyname;

-- 6. Tester si un utilisateur peut faire un UPDATE sur son profil
-- (Remplacez 'USER_ID_ICI' par un vrai UUID d'utilisateur)
-- SELECT * FROM profiles WHERE id = 'USER_ID_ICI';

-- 7. Vérifier les extensions actives
SELECT 
    extname,
    extversion
FROM pg_extension
ORDER BY extname;

-- 8. Vérifier les erreurs récentes (logs si disponibles)
-- SELECT * FROM supabase_functions.http_request_log ORDER BY created_at DESC LIMIT 20;

-- 9. Test de la fonction has_role (si elle existe)
SELECT routine_name, routine_type
FROM information_schema.routines
WHERE routine_schema = 'public'
AND routine_name = 'has_role';

-- 10. Statistiques sur les profils
SELECT 
    COUNT(*) as total_profiles,
    COUNT(avatar_url) as profiles_with_avatar,
    COUNT(*) FILTER (WHERE avatar_url IS NOT NULL AND avatar_url != '') as non_empty_avatars
FROM profiles;
