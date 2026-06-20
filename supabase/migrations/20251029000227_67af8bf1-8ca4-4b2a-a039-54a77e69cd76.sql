-- 🆔 SYSTÈME D'IDENTIFIANTS STANDARDISÉS 224SOLUTIONS
-- Format universel: AAA0001 (3 lettres + 4+ chiffres)

-- Table centrale pour gérer les compteurs par préfixe
CREATE TABLE IF NOT EXISTS public.id_counters (
  prefix VARCHAR(3) PRIMARY KEY,
  current_value INTEGER NOT NULL DEFAULT 0,
  description TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT prefix_format CHECK (prefix ~ '^[A-Z]{3}$')
);

-- Index pour performance
CREATE INDEX IF NOT EXISTS idx_id_counters_prefix ON public.id_counters(prefix);

-- Initialiser les préfixes standards
INSERT INTO public.id_counters (prefix, current_value, description) VALUES
  ('USR', 0, 'Utilisateurs'),
  ('VND', 0, 'Vendeurs'),
  ('PDG', 0, 'PDG'),
  ('AGT', 0, 'Agents'),
  ('SAG', 0, 'Sous-agents'),
  ('SYD', 0, 'Syndicats'),
  ('DRV', 0, 'Livreurs'),
  ('CLI', 0, 'Clients'),
  ('PRD', 0, 'Produits'),
  ('ORD', 0, 'Commandes'),
  ('TXN', 0, 'Transactions'),
  ('WLT', 0, 'Wallets'),
  ('MSG', 0, 'Messages'),
  ('CNV', 0, 'Conversations'),
  ('DLV', 0, 'Livraisons')
ON CONFLICT (prefix) DO NOTHING;

-- Fonction pour générer un ID séquentiel universel
CREATE OR REPLACE FUNCTION public.generate_sequential_id(p_prefix VARCHAR(3))
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_next_value INTEGER;
  v_new_id TEXT;
  v_num_digits INTEGER;
BEGIN
  -- Valider le préfixe
  IF p_prefix !~ '^[A-Z]{3}$' THEN
    RAISE EXCEPTION 'Préfixe invalide: doit être 3 lettres majuscules';
  END IF;

  -- Incrémenter le compteur de manière atomique
  UPDATE public.id_counters
  SET current_value = current_value + 1,
      updated_at = NOW()
  WHERE prefix = p_prefix
  RETURNING current_value INTO v_next_value;

  -- Si le préfixe n'existe pas, le créer
  IF v_next_value IS NULL THEN
    INSERT INTO public.id_counters (prefix, current_value, description)
    VALUES (p_prefix, 1, 'Auto-créé')
    ON CONFLICT (prefix) DO UPDATE SET current_value = current_value + 1
    RETURNING current_value INTO v_next_value;
  END IF;

  -- Calculer le nombre de chiffres nécessaires (minimum 4)
  v_num_digits := GREATEST(4, LENGTH(v_next_value::TEXT));

  -- Générer l'ID au format AAA0001
  v_new_id := p_prefix || LPAD(v_next_value::TEXT, v_num_digits, '0');

  RETURN v_new_id;
END;
$$;

-- Fonction pour obtenir le prochain ID sans l'incrémenter (preview)
CREATE OR REPLACE FUNCTION public.preview_next_id(p_prefix VARCHAR(3))
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_current_value INTEGER;
  v_next_value INTEGER;
  v_num_digits INTEGER;
BEGIN
  SELECT current_value INTO v_current_value
  FROM public.id_counters
  WHERE prefix = p_prefix;

  IF v_current_value IS NULL THEN
    v_next_value := 1;
  ELSE
    v_next_value := v_current_value + 1;
  END IF;

  v_num_digits := GREATEST(4, LENGTH(v_next_value::TEXT));

  RETURN p_prefix || LPAD(v_next_value::TEXT, v_num_digits, '0');
END;
$$;

-- Fonction pour valider un ID standardisé
CREATE OR REPLACE FUNCTION public.validate_standard_id(p_id TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  -- Format: 3 lettres majuscules + au moins 4 chiffres
  RETURN p_id ~ '^[A-Z]{3}\d{4,}$';
END;
$$;

-- Fonction pour extraire le préfixe d'un ID
CREATE OR REPLACE FUNCTION public.extract_prefix(p_id TEXT)
RETURNS VARCHAR(3)
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  IF validate_standard_id(p_id) THEN
    RETURN SUBSTRING(p_id FROM 1 FOR 3);
  END IF;
  RETURN NULL;
END;
$$;

-- Fonction pour extraire le numéro d'un ID
CREATE OR REPLACE FUNCTION public.extract_number(p_id TEXT)
RETURNS INTEGER
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  IF validate_standard_id(p_id) THEN
    RETURN SUBSTRING(p_id FROM 4)::INTEGER;
  END IF;
  RETURN NULL;
END;
$$;

-- Trigger pour mettre à jour updated_at
CREATE OR REPLACE FUNCTION public.update_id_counters_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_update_id_counters_updated_at ON public.id_counters;
CREATE TRIGGER trigger_update_id_counters_updated_at
  BEFORE UPDATE ON public.id_counters
  FOR EACH ROW
  EXECUTE FUNCTION public.update_id_counters_updated_at();

-- Table de mapping pour la migration (anciens IDs -> nouveaux IDs)
CREATE TABLE IF NOT EXISTS public.id_migration_map (
  old_id TEXT NOT NULL,
  new_id TEXT NOT NULL,
  table_name TEXT NOT NULL,
  prefix VARCHAR(3) NOT NULL,
  migrated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (old_id, table_name)
);

CREATE INDEX IF NOT EXISTS idx_id_migration_map_new_id ON public.id_migration_map(new_id);
CREATE INDEX IF NOT EXISTS idx_id_migration_map_table ON public.id_migration_map(table_name);

-- Fonction de migration des IDs existants
CREATE OR REPLACE FUNCTION public.migrate_existing_ids()
RETURNS TABLE(
  table_name TEXT,
  old_id TEXT,
  new_id TEXT,
  status TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_record RECORD;
  v_new_id TEXT;
  v_prefix VARCHAR(3);
BEGIN
  -- Migrer les user_ids (custom_id)
  FOR v_record IN 
    SELECT ui.custom_id, ui.user_id, p.role
    FROM public.user_ids ui
    LEFT JOIN public.profiles p ON p.id = ui.user_id
    WHERE ui.custom_id IS NOT NULL
    AND NOT validate_standard_id(ui.custom_id)
    ORDER BY ui.created_at
  LOOP
    -- Déterminer le préfixe selon le rôle
    v_prefix := CASE 
      WHEN v_record.role = 'vendor' THEN 'VND'
      WHEN v_record.role = 'driver' THEN 'DRV'
      WHEN v_record.role = 'agent' THEN 'AGT'
      WHEN v_record.role = 'pdg' THEN 'PDG'
      ELSE 'USR'
    END;

    v_new_id := generate_sequential_id(v_prefix);

    -- Enregistrer le mapping
    INSERT INTO public.id_migration_map (old_id, new_id, table_name, prefix)
    VALUES (v_record.custom_id, v_new_id, 'user_ids', v_prefix)
    ON CONFLICT DO NOTHING;

    RETURN QUERY SELECT 'user_ids'::TEXT, v_record.custom_id, v_new_id, 'migrated'::TEXT;
  END LOOP;

  -- Migrer les profiles (public_id et custom_id)
  FOR v_record IN
    SELECT id, public_id, custom_id, role
    FROM public.profiles
    WHERE (public_id IS NOT NULL AND NOT validate_standard_id(public_id))
       OR (custom_id IS NOT NULL AND NOT validate_standard_id(custom_id))
    ORDER BY created_at
  LOOP
    v_prefix := CASE 
      WHEN v_record.role = 'vendor' THEN 'VND'
      WHEN v_record.role = 'driver' THEN 'DRV'
      WHEN v_record.role = 'agent' THEN 'AGT'
      WHEN v_record.role = 'pdg' THEN 'PDG'
      ELSE 'USR'
    END;

    v_new_id := generate_sequential_id(v_prefix);

    IF v_record.public_id IS NOT NULL THEN
      INSERT INTO public.id_migration_map (old_id, new_id, table_name, prefix)
      VALUES (v_record.public_id, v_new_id, 'profiles', v_prefix)
      ON CONFLICT DO NOTHING;

      RETURN QUERY SELECT 'profiles'::TEXT, v_record.public_id, v_new_id, 'migrated'::TEXT;
    END IF;
  END LOOP;

  -- Migrer les vendors
  FOR v_record IN
    SELECT id, public_id FROM public.vendors
    WHERE public_id IS NOT NULL AND NOT validate_standard_id(public_id)
    ORDER BY created_at
  LOOP
    v_new_id := generate_sequential_id('VND');

    INSERT INTO public.id_migration_map (old_id, new_id, table_name, prefix)
    VALUES (v_record.public_id, v_new_id, 'vendors', 'VND')
    ON CONFLICT DO NOTHING;

    RETURN QUERY SELECT 'vendors'::TEXT, v_record.public_id, v_new_id, 'migrated'::TEXT;
  END LOOP;

  -- Migrer les products
  FOR v_record IN
    SELECT id, public_id FROM public.products
    WHERE public_id IS NOT NULL AND NOT validate_standard_id(public_id)
    ORDER BY created_at
  LOOP
    v_new_id := generate_sequential_id('PRD');

    INSERT INTO public.id_migration_map (old_id, new_id, table_name, prefix)
    VALUES (v_record.public_id, v_new_id, 'products', 'PRD')
    ON CONFLICT DO NOTHING;

    RETURN QUERY SELECT 'products'::TEXT, v_record.public_id, v_new_id, 'migrated'::TEXT;
  END LOOP;

  -- Migrer les wallets
  FOR v_record IN
    SELECT id, public_id FROM public.wallets
    WHERE public_id IS NOT NULL AND NOT validate_standard_id(public_id)
    ORDER BY created_at
  LOOP
    v_new_id := generate_sequential_id('WLT');

    INSERT INTO public.id_migration_map (old_id, new_id, table_name, prefix)
    VALUES (v_record.public_id, v_new_id, 'wallets', 'WLT')
    ON CONFLICT DO NOTHING;

    RETURN QUERY SELECT 'wallets'::TEXT, v_record.public_id, v_new_id, 'migrated'::TEXT;
  END LOOP;

END;
$$;

COMMENT ON TABLE public.id_counters IS 'Compteurs séquentiels pour génération d''IDs standardisés par préfixe';
COMMENT ON FUNCTION public.generate_sequential_id IS 'Génère un ID séquentiel au format AAA0001';
COMMENT ON FUNCTION public.validate_standard_id IS 'Valide qu''un ID respecte le format standardisé';
COMMENT ON TABLE public.id_migration_map IS 'Mapping anciens IDs → nouveaux IDs pour la migration';