-- Modifier la colonne setting_value pour accepter des valeurs plus longues (TEXT au lieu de varchar(50))
ALTER TABLE public.system_settings 
ALTER COLUMN setting_value TYPE TEXT;