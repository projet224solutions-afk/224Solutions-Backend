-- =============================================
-- SYSTÈME DE ROTATION AUTOMATIQUE MARKETPLACE
-- Rotation équitable des produits toutes les 30 minutes
-- =============================================

-- 1️⃣ Ajouter marketplace_position aux produits
ALTER TABLE public.products 
ADD COLUMN IF NOT EXISTS marketplace_position integer DEFAULT 0,
ADD COLUMN IF NOT EXISTS is_sponsored boolean DEFAULT false,
ADD COLUMN IF NOT EXISTS sponsored_until timestamptz;

-- 2️⃣ Ajouter marketplace_position aux produits numériques
ALTER TABLE public.digital_products 
ADD COLUMN IF NOT EXISTS marketplace_position integer DEFAULT 0,
ADD COLUMN IF NOT EXISTS is_sponsored boolean DEFAULT false,
ADD COLUMN IF NOT EXISTS sponsored_until timestamptz;

-- 3️⃣ Table de configuration et suivi de la rotation
CREATE TABLE IF NOT EXISTS public.marketplace_rotation_config (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_size integer NOT NULL DEFAULT 12,
  rotation_interval_minutes integer NOT NULL DEFAULT 30,
  last_rotation_at timestamptz NOT NULL DEFAULT now(),
  current_batch_offset integer NOT NULL DEFAULT 0,
  total_batches integer NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- 4️⃣ Historique des rotations (audit)
CREATE TABLE IF NOT EXISTS public.marketplace_rotation_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rotation_at timestamptz NOT NULL DEFAULT now(),
  products_rotated integer NOT NULL DEFAULT 0,
  digital_products_rotated integer NOT NULL DEFAULT 0,
  batch_offset_before integer NOT NULL,
  batch_offset_after integer NOT NULL,
  duration_ms integer,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- 5️⃣ Index pour performance
CREATE INDEX IF NOT EXISTS idx_products_marketplace_position ON public.products(marketplace_position);
CREATE INDEX IF NOT EXISTS idx_products_is_sponsored ON public.products(is_sponsored) WHERE is_sponsored = true;
CREATE INDEX IF NOT EXISTS idx_digital_products_marketplace_position ON public.digital_products(marketplace_position);
CREATE INDEX IF NOT EXISTS idx_digital_products_is_sponsored ON public.digital_products(is_sponsored) WHERE is_sponsored = true;

-- 6️⃣ Insérer configuration par défaut
INSERT INTO public.marketplace_rotation_config (batch_size, rotation_interval_minutes)
VALUES (12, 30)
ON CONFLICT DO NOTHING;

-- 7️⃣ Initialiser les positions des produits existants
-- Les produits sponsorisés auront une position négative (toujours en tête)
-- Les autres auront une position basée sur leur date de création
WITH numbered_products AS (
  SELECT id, 
         ROW_NUMBER() OVER (ORDER BY created_at DESC) as rn,
         COALESCE(is_sponsored, false) as sponsored
  FROM public.products
  WHERE is_active = true
)
UPDATE public.products p
SET marketplace_position = CASE 
  WHEN np.sponsored THEN -1 * np.rn 
  ELSE np.rn 
END
FROM numbered_products np
WHERE p.id = np.id;

WITH numbered_digital AS (
  SELECT id, 
         ROW_NUMBER() OVER (ORDER BY created_at DESC) as rn,
         COALESCE(is_sponsored, false) as sponsored
  FROM public.digital_products
  WHERE status = 'published'
)
UPDATE public.digital_products dp
SET marketplace_position = CASE 
  WHEN nd.sponsored THEN -1 * nd.rn 
  ELSE nd.rn 
END
FROM numbered_digital nd
WHERE dp.id = nd.id;

-- 8️⃣ Fonction de rotation des produits
CREATE OR REPLACE FUNCTION public.rotate_marketplace_products()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_config marketplace_rotation_config%ROWTYPE;
  v_total_products integer;
  v_total_digital integer;
  v_total_batches integer;
  v_new_offset integer;
  v_start_time timestamptz := clock_timestamp();
  v_products_updated integer := 0;
  v_digital_updated integer := 0;
BEGIN
  -- Récupérer la configuration
  SELECT * INTO v_config FROM marketplace_rotation_config WHERE is_active = true LIMIT 1;
  
  IF v_config IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No active rotation config found');
  END IF;

  -- Compter les produits actifs non-sponsorisés
  SELECT COUNT(*) INTO v_total_products 
  FROM products 
  WHERE is_active = true AND COALESCE(is_sponsored, false) = false;
  
  SELECT COUNT(*) INTO v_total_digital 
  FROM digital_products 
  WHERE status = 'published' AND COALESCE(is_sponsored, false) = false;

  -- Calculer le nombre total de lots
  v_total_batches := GREATEST(
    CEIL(v_total_products::float / v_config.batch_size),
    CEIL(v_total_digital::float / v_config.batch_size),
    1
  );

  -- Calculer le nouvel offset (rotation circulaire)
  v_new_offset := (v_config.current_batch_offset + 1) % v_total_batches;

  -- ROTATION DES PRODUITS E-COMMERCE
  -- Le dernier lot remonte en première position, les autres descendent
  WITH product_batches AS (
    SELECT id,
           marketplace_position as old_position,
           NTILE(v_total_batches) OVER (ORDER BY marketplace_position) as batch_num
    FROM products
    WHERE is_active = true AND COALESCE(is_sponsored, false) = false
  ),
  new_positions AS (
    SELECT id,
           -- Rotation: batch N devient batch (N - v_new_offset) mod total
           ROW_NUMBER() OVER (
             ORDER BY (batch_num + v_total_batches - v_new_offset) % v_total_batches,
                      old_position
           ) as new_pos
    FROM product_batches
  )
  UPDATE products p
  SET marketplace_position = np.new_pos,
      updated_at = now()
  FROM new_positions np
  WHERE p.id = np.id;
  
  GET DIAGNOSTICS v_products_updated = ROW_COUNT;

  -- ROTATION DES PRODUITS NUMÉRIQUES (même logique)
  WITH digital_batches AS (
    SELECT id,
           marketplace_position as old_position,
           NTILE(v_total_batches) OVER (ORDER BY marketplace_position) as batch_num
    FROM digital_products
    WHERE status = 'published' AND COALESCE(is_sponsored, false) = false
  ),
  new_digital_positions AS (
    SELECT id,
           ROW_NUMBER() OVER (
             ORDER BY (batch_num + v_total_batches - v_new_offset) % v_total_batches,
                      old_position
           ) as new_pos
    FROM digital_batches
  )
  UPDATE digital_products dp
  SET marketplace_position = ndp.new_pos,
      updated_at = now()
  FROM new_digital_positions ndp
  WHERE dp.id = ndp.id;
  
  GET DIAGNOSTICS v_digital_updated = ROW_COUNT;

  -- Mettre à jour la configuration
  UPDATE marketplace_rotation_config
  SET current_batch_offset = v_new_offset,
      total_batches = v_total_batches,
      last_rotation_at = now(),
      updated_at = now()
  WHERE id = v_config.id;

  -- Logger l'historique
  INSERT INTO marketplace_rotation_history (
    products_rotated, 
    digital_products_rotated,
    batch_offset_before, 
    batch_offset_after,
    duration_ms
  ) VALUES (
    v_products_updated,
    v_digital_updated,
    v_config.current_batch_offset,
    v_new_offset,
    EXTRACT(MILLISECONDS FROM clock_timestamp() - v_start_time)::integer
  );

  RETURN jsonb_build_object(
    'success', true,
    'products_rotated', v_products_updated,
    'digital_products_rotated', v_digital_updated,
    'total_batches', v_total_batches,
    'new_batch_offset', v_new_offset,
    'duration_ms', EXTRACT(MILLISECONDS FROM clock_timestamp() - v_start_time)::integer
  );
END;
$$;

-- 9️⃣ RLS pour les tables de rotation
ALTER TABLE public.marketplace_rotation_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_rotation_history ENABLE ROW LEVEL SECURITY;

-- Admins peuvent lire la config
CREATE POLICY "admins_read_rotation_config" ON public.marketplace_rotation_config
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

CREATE POLICY "admins_read_rotation_history" ON public.marketplace_rotation_history
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- Service role peut tout faire (pour les cron jobs)
CREATE POLICY "service_role_all_rotation_config" ON public.marketplace_rotation_config
  FOR ALL USING (auth.role() = 'service_role');

CREATE POLICY "service_role_all_rotation_history" ON public.marketplace_rotation_history
  FOR ALL USING (auth.role() = 'service_role');

-- 🔟 Trigger pour mettre à jour updated_at
CREATE OR REPLACE FUNCTION update_rotation_config_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_update_rotation_config ON marketplace_rotation_config;
CREATE TRIGGER trigger_update_rotation_config
  BEFORE UPDATE ON marketplace_rotation_config
  FOR EACH ROW
  EXECUTE FUNCTION update_rotation_config_updated_at();