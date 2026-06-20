-- ==========================================
-- MIGRATION: Système d'ID unique LLLDDDD
-- ==========================================

-- 1. Table de réservation des IDs (évite les doublons)
CREATE TABLE IF NOT EXISTS public.ids_reserved (
  public_id VARCHAR(8) PRIMARY KEY,
  scope VARCHAR(50) NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  created_by UUID REFERENCES auth.users(id)
);

-- Index pour recherche par scope
CREATE INDEX IF NOT EXISTS idx_ids_reserved_scope ON public.ids_reserved(scope);

-- RLS pour ids_reserved
ALTER TABLE public.ids_reserved ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Service role can manage ids_reserved"
ON public.ids_reserved FOR ALL
USING (auth.role() = 'service_role');

CREATE POLICY "Users can view reserved IDs"
ON public.ids_reserved FOR SELECT
USING (true);

-- 2. Ajouter public_id aux tables existantes
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS public_id VARCHAR(8) UNIQUE;
ALTER TABLE public.drivers ADD COLUMN IF NOT EXISTS public_id VARCHAR(8) UNIQUE;
ALTER TABLE public.vendors ADD COLUMN IF NOT EXISTS public_id VARCHAR(8) UNIQUE;
ALTER TABLE public.customers ADD COLUMN IF NOT EXISTS public_id VARCHAR(8) UNIQUE;
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS public_id VARCHAR(8) UNIQUE;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS public_id VARCHAR(8) UNIQUE;
ALTER TABLE public.deliveries ADD COLUMN IF NOT EXISTS public_id VARCHAR(8) UNIQUE;
ALTER TABLE public.enhanced_transactions ADD COLUMN IF NOT EXISTS public_id VARCHAR(8) UNIQUE;
ALTER TABLE public.messages ADD COLUMN IF NOT EXISTS public_id VARCHAR(8) UNIQUE;
ALTER TABLE public.conversations ADD COLUMN IF NOT EXISTS public_id VARCHAR(8) UNIQUE;

-- Index uniques pour chaque table
CREATE UNIQUE INDEX IF NOT EXISTS idx_public_id_profiles ON public.profiles(public_id) WHERE public_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_public_id_drivers ON public.drivers(public_id) WHERE public_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_public_id_vendors ON public.vendors(public_id) WHERE public_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_public_id_customers ON public.customers(public_id) WHERE public_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_public_id_products ON public.products(public_id) WHERE public_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_public_id_orders ON public.orders(public_id) WHERE public_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_public_id_deliveries ON public.deliveries(public_id) WHERE public_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_public_id_transactions ON public.enhanced_transactions(public_id) WHERE public_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_public_id_messages ON public.messages(public_id) WHERE public_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_public_id_conversations ON public.conversations(public_id) WHERE public_id IS NOT NULL;

-- 3. Fonction améliorée de génération d'ID (3 lettres + 4 chiffres, exclut I, L, O)
CREATE OR REPLACE FUNCTION generate_public_id() RETURNS TEXT AS $$
DECLARE
    v_letters TEXT := 'ABCDEFGHJKMNPQRSTUVWXYZ'; -- Exclut I, L, O
    v_numbers TEXT := '0123456789';
    v_result TEXT := '';
    v_i INTEGER;
BEGIN
    -- Générer 3 lettres aléatoires
    FOR v_i IN 1..3 LOOP
        v_result := v_result || substr(v_letters, floor(random() * length(v_letters) + 1)::integer, 1);
    END LOOP;
    
    -- Générer 4 chiffres aléatoires
    FOR v_i IN 1..4 LOOP
        v_result := v_result || substr(v_numbers, floor(random() * length(v_numbers) + 1)::integer, 1);
    END LOOP;
    
    RETURN v_result;
END;
$$ LANGUAGE plpgsql;

-- 4. Fonction pour générer un ID unique avec vérification
CREATE OR REPLACE FUNCTION generate_unique_public_id(p_scope TEXT) RETURNS TEXT AS $$
DECLARE
    v_new_id TEXT;
    v_attempt INTEGER := 0;
    v_exists BOOLEAN;
BEGIN
    WHILE v_attempt < 10 LOOP
        v_new_id := generate_public_id();
        
        -- Vérifier si l'ID existe déjà dans ids_reserved
        SELECT EXISTS(SELECT 1 FROM public.ids_reserved WHERE public_id = v_new_id) INTO v_exists;
        
        IF NOT v_exists THEN
            -- Réserver l'ID
            INSERT INTO public.ids_reserved (public_id, scope, created_by)
            VALUES (v_new_id, p_scope, auth.uid());
            
            RETURN v_new_id;
        END IF;
        
        v_attempt := v_attempt + 1;
    END LOOP;
    
    RAISE EXCEPTION 'Impossible de générer un ID unique après 10 tentatives';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 5. Table de logs pour la génération d'IDs
CREATE TABLE IF NOT EXISTS public.id_generation_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  action TEXT NOT NULL DEFAULT 'ID_GENERATION',
  public_id VARCHAR(8) NOT NULL,
  scope VARCHAR(50) NOT NULL,
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  metadata JSONB DEFAULT '{}'
);

-- Index pour les logs
CREATE INDEX IF NOT EXISTS idx_id_logs_public_id ON public.id_generation_logs(public_id);
CREATE INDEX IF NOT EXISTS idx_id_logs_scope ON public.id_generation_logs(scope);
CREATE INDEX IF NOT EXISTS idx_id_logs_created_at ON public.id_generation_logs(created_at DESC);

-- RLS pour les logs
ALTER TABLE public.id_generation_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Service role can manage logs"
ON public.id_generation_logs FOR ALL
USING (auth.role() = 'service_role');

CREATE POLICY "Admins can view logs"
ON public.id_generation_logs FOR SELECT
USING (has_role(auth.uid(), 'admin'::user_role));

-- 6. Trigger pour logger la génération d'IDs
CREATE OR REPLACE FUNCTION log_id_generation() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.public_id IS NOT NULL THEN
        INSERT INTO public.id_generation_logs (public_id, scope, created_by, metadata)
        VALUES (NEW.public_id, TG_TABLE_NAME, auth.uid(), jsonb_build_object(
            'table', TG_TABLE_NAME,
            'record_id', NEW.id
        ));
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Appliquer le trigger aux tables principales
DROP TRIGGER IF EXISTS log_id_profiles ON public.profiles;
CREATE TRIGGER log_id_profiles AFTER INSERT OR UPDATE ON public.profiles
FOR EACH ROW WHEN (NEW.public_id IS NOT NULL)
EXECUTE FUNCTION log_id_generation();

DROP TRIGGER IF EXISTS log_id_drivers ON public.drivers;
CREATE TRIGGER log_id_drivers AFTER INSERT OR UPDATE ON public.drivers
FOR EACH ROW WHEN (NEW.public_id IS NOT NULL)
EXECUTE FUNCTION log_id_generation();

DROP TRIGGER IF EXISTS log_id_vendors ON public.vendors;
CREATE TRIGGER log_id_vendors AFTER INSERT OR UPDATE ON public.vendors
FOR EACH ROW WHEN (NEW.public_id IS NOT NULL)
EXECUTE FUNCTION log_id_generation();

DROP TRIGGER IF EXISTS log_id_products ON public.products;
CREATE TRIGGER log_id_products AFTER INSERT OR UPDATE ON public.products
FOR EACH ROW WHEN (NEW.public_id IS NOT NULL)
EXECUTE FUNCTION log_id_generation();

DROP TRIGGER IF EXISTS log_id_orders ON public.orders;
CREATE TRIGGER log_id_orders AFTER INSERT OR UPDATE ON public.orders
FOR EACH ROW WHEN (NEW.public_id IS NOT NULL)
EXECUTE FUNCTION log_id_generation();