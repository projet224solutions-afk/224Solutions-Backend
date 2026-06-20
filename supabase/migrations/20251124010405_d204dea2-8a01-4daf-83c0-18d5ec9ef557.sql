-- Migration: Corriger la génération d'ID pour utiliser le système standardisé séquentiel
-- Remplacer generate_custom_id() par generate_sequential_id() dans le trigger

-- 1. Fonction améliorée pour créer automatiquement un profil avec ID séquentiel standardisé
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_custom_id TEXT;
  v_role TEXT;
  v_prefix VARCHAR(3);
BEGIN
  -- Récupérer le rôle de l'utilisateur
  v_role := COALESCE(NEW.raw_user_meta_data->>'role', 'client');
  
  -- Déterminer le préfixe en fonction du rôle
  CASE v_role
    WHEN 'vendeur' THEN v_prefix := 'VND';
    WHEN 'client' THEN v_prefix := 'CLI';
    WHEN 'livreur' THEN v_prefix := 'DLV';
    WHEN 'taxi' THEN v_prefix := 'DRV';
    WHEN 'syndicat' THEN v_prefix := 'SYD';
    WHEN 'transitaire' THEN v_prefix := 'TRA';
    WHEN 'admin' THEN v_prefix := 'ADM';
    WHEN 'agent' THEN v_prefix := 'AGT';
    WHEN 'pdg' THEN v_prefix := 'PDG';
    ELSE v_prefix := 'USR';
  END CASE;
  
  -- Générer un custom_id séquentiel standardisé
  v_custom_id := generate_sequential_id(v_prefix);
  
  -- Créer le profil utilisateur
  INSERT INTO public.profiles (
    id, 
    email, 
    full_name,
    first_name,
    last_name,
    custom_id,
    role,
    created_at,
    updated_at
  )
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.raw_user_meta_data->>'name', 'Utilisateur'),
    COALESCE(NEW.raw_user_meta_data->>'first_name', ''),
    COALESCE(NEW.raw_user_meta_data->>'last_name', ''),
    v_custom_id,
    v_role::user_role,
    NOW(),
    NOW()
  )
  ON CONFLICT (id) DO NOTHING;
  
  -- Créer l'entrée dans user_ids
  INSERT INTO public.user_ids (user_id, custom_id, created_at)
  VALUES (NEW.id, v_custom_id, NOW())
  ON CONFLICT (user_id) DO NOTHING;
  
  -- Initialiser le wallet
  INSERT INTO public.wallets (user_id, balance, currency, wallet_status, created_at, updated_at)
  VALUES (NEW.id, 0, 'GNF', 'active', NOW(), NOW())
  ON CONFLICT (user_id, currency) DO NOTHING;
  
  RETURN NEW;
END;
$$;

-- 2. Mettre à jour le commentaire
COMMENT ON FUNCTION public.handle_new_user() IS 'Trigger automatique pour créer un profil avec ID séquentiel standardisé, user_id et wallet lors de l''inscription';

-- 3. Fonction pour corriger les IDs existants en format aléatoire vers format séquentiel
CREATE OR REPLACE FUNCTION public.migrate_random_ids_to_sequential()
RETURNS TABLE(profile_user_id UUID, old_id TEXT, new_id TEXT, status TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user RECORD;
  v_new_id TEXT;
  v_prefix VARCHAR(3);
BEGIN
  -- Parcourir tous les utilisateurs avec des IDs au format aléatoire (3 lettres + 4 chiffres)
  FOR v_user IN 
    SELECT p.id, p.custom_id, p.role
    FROM public.profiles p
    WHERE p.custom_id ~ '^[A-Z]{3}[0-9]{4}$'  -- Format aléatoire LLLDDDD
    AND p.custom_id !~ '^(VND|CLI|DLV|DRV|SYD|TRA|ADM|AGT|PDG|USR)[0-9]{4,}$'  -- Pas déjà au format standardisé
  LOOP
    -- Déterminer le préfixe en fonction du rôle
    CASE v_user.role::text
      WHEN 'vendeur' THEN v_prefix := 'VND';
      WHEN 'client' THEN v_prefix := 'CLI';
      WHEN 'livreur' THEN v_prefix := 'DLV';
      WHEN 'taxi' THEN v_prefix := 'DRV';
      WHEN 'syndicat' THEN v_prefix := 'SYD';
      WHEN 'transitaire' THEN v_prefix := 'TRA';
      WHEN 'admin' THEN v_prefix := 'ADM';
      WHEN 'agent' THEN v_prefix := 'AGT';
      WHEN 'pdg' THEN v_prefix := 'PDG';
      ELSE v_prefix := 'USR';
    END CASE;
    
    -- Générer un nouvel ID séquentiel standardisé
    v_new_id := generate_sequential_id(v_prefix);
    
    -- Mettre à jour le profil
    UPDATE public.profiles
    SET custom_id = v_new_id
    WHERE id = v_user.id;
    
    -- Mettre à jour user_ids (qualification explicite)
    UPDATE public.user_ids
    SET custom_id = v_new_id
    WHERE user_ids.user_id = v_user.id;
    
    profile_user_id := v_user.id;
    old_id := v_user.custom_id;
    new_id := v_new_id;
    status := 'migrated';
    RETURN NEXT;
  END LOOP;
END;
$$;

-- 4. Exécuter la migration des IDs existants
SELECT * FROM public.migrate_random_ids_to_sequential();

-- 5. Ajouter un commentaire
COMMENT ON FUNCTION public.migrate_random_ids_to_sequential() IS 'Migre les IDs aléatoires existants vers le format séquentiel standardisé';