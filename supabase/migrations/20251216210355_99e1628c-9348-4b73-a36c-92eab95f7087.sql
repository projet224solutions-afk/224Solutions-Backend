-- Ensure pgcrypto extension is enabled and accessible
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- Fix generate_badge_code function to use extensions schema
CREATE OR REPLACE FUNCTION public.generate_badge_code()
RETURNS TEXT AS $$
BEGIN
    RETURN encode(extensions.gen_random_bytes(16), 'hex');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions;

-- Fix generate_invite_token function
CREATE OR REPLACE FUNCTION public.generate_invite_token()
RETURNS TEXT AS $$
BEGIN
    RETURN encode(extensions.gen_random_bytes(32), 'base64url');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions;

-- Fix generate_api_key function
CREATE OR REPLACE FUNCTION public.generate_api_key()
RETURNS TEXT AS $$
BEGIN
  RETURN '224_' || encode(extensions.gen_random_bytes(32), 'base64');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions;

-- Fix generate_unique_agent_token function
CREATE OR REPLACE FUNCTION public.generate_unique_agent_token()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  token TEXT;
  token_exists BOOLEAN;
BEGIN
  LOOP
    token := encode(extensions.gen_random_bytes(24), 'base64');
    token := replace(token, '/', '_');
    token := replace(token, '+', '-');
    token := replace(token, '=', '');
    
    SELECT EXISTS(SELECT 1 FROM agents_management WHERE access_token = token) INTO token_exists;
    
    IF NOT token_exists THEN
      RETURN token;
    END IF;
  END LOOP;
END;
$$;

-- Fix generate_unique_invitation_token function
CREATE OR REPLACE FUNCTION public.generate_unique_invitation_token()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  new_token TEXT;
BEGIN
  LOOP
    new_token := encode(extensions.gen_random_bytes(32), 'base64');
    new_token := replace(replace(replace(new_token, '/', '_'), '+', '-'), '=', '');
    
    IF NOT EXISTS (SELECT 1 FROM public.agent_invitations WHERE invitation_token = new_token) THEN
      RETURN new_token;
    END IF;
  END LOOP;
END;
$$;

-- Fix generate_secure_token function  
CREATE OR REPLACE FUNCTION public.generate_secure_token()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  RETURN encode(extensions.gen_random_bytes(32), 'hex');
END;
$$;