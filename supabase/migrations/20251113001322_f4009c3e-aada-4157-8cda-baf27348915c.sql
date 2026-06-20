-- Corriger la fonction pour utiliser explicitement le schéma extensions
CREATE OR REPLACE FUNCTION public.generate_vendor_agent_access_token()
RETURNS TEXT AS $$
DECLARE
  token TEXT;
  token_exists BOOLEAN;
BEGIN
  LOOP
    -- Utiliser explicitement extensions.gen_random_bytes
    token := encode(extensions.gen_random_bytes(24), 'base64');
    token := replace(token, '/', '_');
    token := replace(token, '+', '-');
    token := replace(token, '=', '');
    
    -- Vérifier si le token existe déjà
    SELECT EXISTS(SELECT 1 FROM public.vendor_agents WHERE access_token = token)
    INTO token_exists;
    
    EXIT WHEN NOT token_exists;
  END LOOP;
  
  RETURN token;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;