-- Désactiver temporairement les triggers problématiques sur profiles
ALTER TABLE public.profiles DISABLE TRIGGER trigger_auto_generate_custom_id;
ALTER TABLE public.profiles DISABLE TRIGGER trigger_auto_generate_standard_id;

-- Commentaire
COMMENT ON TABLE public.profiles IS 'Triggers custom_id et standard_id désactivés temporairement pour permettre la création d''utilisateurs via edge function';