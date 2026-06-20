-- =====================================================
-- SYSTÈME DE ROTATION AUTOMATIQUE DU MARKETPLACE
-- 224SOLUTIONS - 29 Janvier 2026
-- =====================================================
-- Objectif: Rotation équitable des produits toutes les 30 minutes
-- pour garantir une visibilité égale à tous les vendeurs
-- =====================================================

-- 1. Ajouter les colonnes nécessaires à la table products
ALTER TABLE public.products 
ADD COLUMN IF NOT EXISTS marketplace_position INTEGER DEFAULT 0,
ADD COLUMN IF NOT EXISTS marketplace_batch INTEGER DEFAULT 0,
ADD COLUMN IF NOT EXISTS is_sponsored BOOLEAN DEFAULT FALSE,
ADD COLUMN IF NOT EXISTS sponsor_priority INTEGER DEFAULT 0,
ADD COLUMN IF NOT EXISTS sponsor_expires_at TIMESTAMP WITH TIME ZONE;

-- Index pour optimiser les requêtes de tri
CREATE INDEX IF NOT EXISTS idx_products_marketplace_position ON products(marketplace_position);
CREATE INDEX IF NOT EXISTS idx_products_marketplace_batch ON products(marketplace_batch);
CREATE INDEX IF NOT EXISTS idx_products_is_sponsored ON products(is_sponsored) WHERE is_sponsored = true;
CREATE INDEX IF NOT EXISTS idx_products_active_position ON products(is_active, marketplace_position) WHERE is_active = true;

-- 2. Ajouter les colonnes aux produits numériques
ALTER TABLE public.digital_products 
ADD COLUMN IF NOT EXISTS marketplace_position INTEGER DEFAULT 0,
ADD COLUMN IF NOT EXISTS marketplace_batch INTEGER DEFAULT 0,
ADD COLUMN IF NOT EXISTS is_sponsored BOOLEAN DEFAULT FALSE,
ADD COLUMN IF NOT EXISTS sponsor_priority INTEGER DEFAULT 0,
ADD COLUMN IF NOT EXISTS sponsor_expires_at TIMESTAMP WITH TIME ZONE;

CREATE INDEX IF NOT EXISTS idx_digital_products_position ON digital_products(marketplace_position);

-- 3. Table de configuration de la rotation
CREATE TABLE IF NOT EXISTS public.marketplace_rotation_config (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_size INTEGER NOT NULL DEFAULT 50,           -- Nombre de produits par lot
  rotation_interval_minutes INTEGER NOT NULL DEFAULT 30, -- Intervalle de rotation
  last_rotation_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  next_rotation_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() + INTERVAL '30 minutes',
  total_batches INTEGER DEFAULT 0,
  current_batch INTEGER DEFAULT 0,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Ajouter les colonnes manquantes si la table existe déjà
ALTER TABLE public.marketplace_rotation_config 
ADD COLUMN IF NOT EXISTS batch_size INTEGER NOT NULL DEFAULT 50;

ALTER TABLE public.marketplace_rotation_config 
ADD COLUMN IF NOT EXISTS rotation_interval_minutes INTEGER NOT NULL DEFAULT 30;

ALTER TABLE public.marketplace_rotation_config 
ADD COLUMN IF NOT EXISTS last_rotation_at TIMESTAMP WITH TIME ZONE DEFAULT NOW();

ALTER TABLE public.marketplace_rotation_config 
ADD COLUMN IF NOT EXISTS next_rotation_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() + INTERVAL '30 minutes';

ALTER TABLE public.marketplace_rotation_config 
ADD COLUMN IF NOT EXISTS total_batches INTEGER DEFAULT 0;

ALTER TABLE public.marketplace_rotation_config 
ADD COLUMN IF NOT EXISTS current_batch INTEGER DEFAULT 0;

ALTER TABLE public.marketplace_rotation_config 
ADD COLUMN IF NOT EXISTS is_active BOOLEAN DEFAULT TRUE;

ALTER TABLE public.marketplace_rotation_config 
ADD COLUMN IF NOT EXISTS created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW();

ALTER TABLE public.marketplace_rotation_config 
ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW();

-- S'assurer qu'il n'y a qu'une seule configuration (créer l'index AVANT l'insert)
CREATE UNIQUE INDEX IF NOT EXISTS idx_marketplace_rotation_config_single 
ON marketplace_rotation_config ((true));

-- Insérer la configuration par défaut (seulement si la table est vide)
INSERT INTO marketplace_rotation_config (batch_size, rotation_interval_minutes)
SELECT 50, 30
WHERE NOT EXISTS (SELECT 1 FROM marketplace_rotation_config);

-- 4. Table d'historique des rotations (pour audit)
CREATE TABLE IF NOT EXISTS public.marketplace_rotation_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  rotation_timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  products_rotated INTEGER DEFAULT 0,
  batches_count INTEGER DEFAULT 0,
  execution_time_ms INTEGER DEFAULT 0,
  status TEXT DEFAULT 'completed', -- 'completed', 'failed', 'partial'
  error_message TEXT,
  metadata JSONB DEFAULT '{}'::JSONB
);

-- Ajouter les colonnes manquantes si la table existe déjà
ALTER TABLE public.marketplace_rotation_history 
ADD COLUMN IF NOT EXISTS rotation_timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW();

ALTER TABLE public.marketplace_rotation_history 
ADD COLUMN IF NOT EXISTS products_rotated INTEGER DEFAULT 0;

ALTER TABLE public.marketplace_rotation_history 
ADD COLUMN IF NOT EXISTS batches_count INTEGER DEFAULT 0;

ALTER TABLE public.marketplace_rotation_history 
ADD COLUMN IF NOT EXISTS execution_time_ms INTEGER DEFAULT 0;

ALTER TABLE public.marketplace_rotation_history 
ADD COLUMN IF NOT EXISTS status TEXT DEFAULT 'completed';

ALTER TABLE public.marketplace_rotation_history 
ADD COLUMN IF NOT EXISTS error_message TEXT;

ALTER TABLE public.marketplace_rotation_history 
ADD COLUMN IF NOT EXISTS metadata JSONB DEFAULT '{}'::JSONB;

CREATE INDEX IF NOT EXISTS idx_rotation_history_timestamp 
ON marketplace_rotation_history(rotation_timestamp DESC);

-- 5. Fonction pour initialiser les positions des produits
CREATE OR REPLACE FUNCTION public.initialize_marketplace_positions()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_config RECORD;
  v_product RECORD;
  v_position INTEGER := 0;
  v_batch INTEGER := 0;
  v_batch_count INTEGER := 0;
  v_products_count INTEGER := 0;
BEGIN
  -- Récupérer la configuration
  SELECT * INTO v_config FROM marketplace_rotation_config LIMIT 1;
  
  IF v_config IS NULL THEN
    -- Créer la configuration par défaut
    INSERT INTO marketplace_rotation_config (batch_size, rotation_interval_minutes)
    VALUES (50, 30)
    RETURNING * INTO v_config;
  END IF;
  
  -- D'abord, assigner les positions aux produits sponsorisés (position négative = en tête)
  -- Utiliser un CTE car les fonctions de fenêtrage ne sont pas autorisées dans UPDATE direct
  WITH sponsored_ranked AS (
    SELECT 
      id,
      ROW_NUMBER() OVER (ORDER BY sponsor_priority DESC, created_at ASC) as rn
    FROM products
    WHERE is_active = true 
      AND is_sponsored = true 
      AND (sponsor_expires_at IS NULL OR sponsor_expires_at > NOW())
  )
  UPDATE products p
  SET marketplace_position = -1 * sr.rn::INTEGER,
      marketplace_batch = -1
  FROM sponsored_ranked sr
  WHERE p.id = sr.id;
  
  -- Ensuite, assigner les positions aux produits normaux
  v_position := 0;
  v_batch := 0;
  v_batch_count := 0;
  
  FOR v_product IN 
    SELECT id 
    FROM products 
    WHERE is_active = true 
      AND (is_sponsored = false OR is_sponsored IS NULL)
    ORDER BY created_at DESC -- Les plus récents d'abord initialement
  LOOP
    -- Incrémenter la position
    v_position := v_position + 1;
    v_batch_count := v_batch_count + 1;
    
    -- Nouveau batch si on atteint la taille du batch
    IF v_batch_count > v_config.batch_size THEN
      v_batch := v_batch + 1;
      v_batch_count := 1;
    END IF;
    
    -- Mettre à jour le produit
    UPDATE products 
    SET marketplace_position = v_position,
        marketplace_batch = v_batch
    WHERE id = v_product.id;
    
    v_products_count := v_products_count + 1;
  END LOOP;
  
  -- Mettre à jour le nombre total de batches
  UPDATE marketplace_rotation_config
  SET total_batches = v_batch + 1,
      current_batch = 0,
      updated_at = NOW();
  
  RETURN jsonb_build_object(
    'success', true,
    'products_initialized', v_products_count,
    'total_batches', v_batch + 1,
    'batch_size', v_config.batch_size
  );
END;
$$;

-- 6. Fonction principale de rotation du marketplace
CREATE OR REPLACE FUNCTION public.rotate_marketplace_products()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_config RECORD;
  v_start_time TIMESTAMP := clock_timestamp();
  v_products_count INTEGER;
  v_max_batch INTEGER;
  v_execution_time INTEGER;
  v_result JSONB;
BEGIN
  -- Récupérer la configuration
  SELECT * INTO v_config FROM marketplace_rotation_config WHERE is_active = true LIMIT 1;
  
  IF v_config IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Configuration de rotation non trouvée'
    );
  END IF;
  
  -- Compter les produits actifs non sponsorisés
  SELECT COUNT(*) INTO v_products_count 
  FROM products 
  WHERE is_active = true 
    AND (is_sponsored = false OR is_sponsored IS NULL);
  
  IF v_products_count = 0 THEN
    RETURN jsonb_build_object(
      'success', true,
      'message', 'Aucun produit à faire tourner',
      'products_count', 0
    );
  END IF;
  
  -- Trouver le batch maximum actuel
  SELECT COALESCE(MAX(marketplace_batch), 0) INTO v_max_batch
  FROM products
  WHERE is_active = true 
    AND (is_sponsored = false OR is_sponsored IS NULL);
  
  -- LOGIQUE DE ROTATION:
  -- 1. Le dernier batch (v_max_batch) devient le batch 0 (première position)
  -- 2. Tous les autres batches descendent d'un niveau (batch N -> batch N+1)
  
  -- Étape 1: Mettre temporairement le dernier batch à -999
  UPDATE products
  SET marketplace_batch = -999
  WHERE marketplace_batch = v_max_batch
    AND is_active = true
    AND (is_sponsored = false OR is_sponsored IS NULL);
  
  -- Étape 2: Incrémenter tous les autres batches de 1
  UPDATE products
  SET marketplace_batch = marketplace_batch + 1
  WHERE marketplace_batch >= 0
    AND marketplace_batch < v_max_batch
    AND is_active = true
    AND (is_sponsored = false OR is_sponsored IS NULL);
  
  -- Étape 3: Le dernier batch devient le batch 0
  UPDATE products
  SET marketplace_batch = 0
  WHERE marketplace_batch = -999
    AND is_active = true
    AND (is_sponsored = false OR is_sponsored IS NULL);
  
  -- Étape 4: Recalculer les positions basées sur le nouveau batch
  WITH ranked_products AS (
    SELECT 
      id,
      ROW_NUMBER() OVER (
        ORDER BY 
          marketplace_batch ASC,
          marketplace_position ASC
      ) as new_position
    FROM products
    WHERE is_active = true
      AND (is_sponsored = false OR is_sponsored IS NULL)
  )
  UPDATE products p
  SET marketplace_position = rp.new_position
  FROM ranked_products rp
  WHERE p.id = rp.id;
  
  -- Mettre à jour la configuration
  UPDATE marketplace_rotation_config
  SET last_rotation_at = NOW(),
      next_rotation_at = NOW() + (rotation_interval_minutes || ' minutes')::INTERVAL,
      current_batch = CASE 
        WHEN current_batch >= total_batches - 1 THEN 0 
        ELSE current_batch + 1 
      END,
      updated_at = NOW()
  WHERE id = v_config.id;
  
  -- Calculer le temps d'exécution
  v_execution_time := EXTRACT(MILLISECOND FROM clock_timestamp() - v_start_time)::INTEGER;
  
  -- Enregistrer dans l'historique
  INSERT INTO marketplace_rotation_history (
    products_rotated,
    batches_count,
    execution_time_ms,
    status,
    metadata
  ) VALUES (
    v_products_count,
    v_max_batch + 1,
    v_execution_time,
    'completed',
    jsonb_build_object(
      'batch_size', v_config.batch_size,
      'previous_first_batch', v_max_batch,
      'new_first_batch', 0
    )
  );
  
  RETURN jsonb_build_object(
    'success', true,
    'products_rotated', v_products_count,
    'batches_count', v_max_batch + 1,
    'execution_time_ms', v_execution_time,
    'next_rotation_at', NOW() + (v_config.rotation_interval_minutes || ' minutes')::INTERVAL
  );
END;
$$;

-- 7. Fonction pour obtenir le temps jusqu'à la prochaine rotation
CREATE OR REPLACE FUNCTION public.get_marketplace_rotation_info()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_config RECORD;
  v_sponsored_count INTEGER;
  v_regular_count INTEGER;
BEGIN
  SELECT * INTO v_config FROM marketplace_rotation_config LIMIT 1;
  
  SELECT COUNT(*) INTO v_sponsored_count
  FROM products
  WHERE is_active = true AND is_sponsored = true
    AND (sponsor_expires_at IS NULL OR sponsor_expires_at > NOW());
  
  SELECT COUNT(*) INTO v_regular_count
  FROM products
  WHERE is_active = true AND (is_sponsored = false OR is_sponsored IS NULL);
  
  RETURN jsonb_build_object(
    'last_rotation_at', v_config.last_rotation_at,
    'next_rotation_at', v_config.next_rotation_at,
    'rotation_interval_minutes', v_config.rotation_interval_minutes,
    'batch_size', v_config.batch_size,
    'total_batches', v_config.total_batches,
    'current_batch', v_config.current_batch,
    'sponsored_products_count', v_sponsored_count,
    'regular_products_count', v_regular_count,
    'is_active', v_config.is_active
  );
END;
$$;

-- 8. Fonction pour sponsoriser un produit
CREATE OR REPLACE FUNCTION public.sponsor_product(
  p_product_id UUID,
  p_duration_days INTEGER DEFAULT 7,
  p_priority INTEGER DEFAULT 1
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_product RECORD;
BEGIN
  -- Vérifier que le produit existe
  SELECT * INTO v_product FROM products WHERE id = p_product_id;
  
  IF v_product IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Produit non trouvé'
    );
  END IF;
  
  -- Mettre à jour le produit comme sponsorisé
  UPDATE products
  SET is_sponsored = true,
      sponsor_priority = p_priority,
      sponsor_expires_at = NOW() + (p_duration_days || ' days')::INTERVAL,
      marketplace_position = -1 * p_priority, -- Position négative = en tête
      marketplace_batch = -1
  WHERE id = p_product_id;
  
  RETURN jsonb_build_object(
    'success', true,
    'product_id', p_product_id,
    'sponsor_expires_at', NOW() + (p_duration_days || ' days')::INTERVAL,
    'priority', p_priority
  );
END;
$$;

-- 9. Fonction pour retirer le sponsoring d'un produit
CREATE OR REPLACE FUNCTION public.unsponsor_product(p_product_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_max_position INTEGER;
BEGIN
  -- Trouver la position maximale actuelle
  SELECT COALESCE(MAX(marketplace_position), 0) INTO v_max_position
  FROM products
  WHERE is_active = true AND (is_sponsored = false OR is_sponsored IS NULL);
  
  -- Retirer le sponsoring et mettre le produit à la fin
  UPDATE products
  SET is_sponsored = false,
      sponsor_priority = 0,
      sponsor_expires_at = NULL,
      marketplace_position = v_max_position + 1,
      marketplace_batch = (
        SELECT COALESCE(MAX(marketplace_batch), 0)
        FROM products
        WHERE is_active = true AND (is_sponsored = false OR is_sponsored IS NULL)
      )
  WHERE id = p_product_id;
  
  RETURN jsonb_build_object(
    'success', true,
    'product_id', p_product_id,
    'new_position', v_max_position + 1
  );
END;
$$;

-- 10. Trigger pour assigner une position aux nouveaux produits
CREATE OR REPLACE FUNCTION public.assign_marketplace_position_to_new_product()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_max_position INTEGER;
  v_max_batch INTEGER;
  v_config RECORD;
BEGIN
  -- Ne pas modifier si c'est un produit sponsorisé
  IF NEW.is_sponsored = true THEN
    NEW.marketplace_position := -1 * COALESCE(NEW.sponsor_priority, 1);
    NEW.marketplace_batch := -1;
    RETURN NEW;
  END IF;
  
  -- Récupérer la configuration
  SELECT * INTO v_config FROM marketplace_rotation_config LIMIT 1;
  
  -- Trouver la position et le batch maximum
  SELECT COALESCE(MAX(marketplace_position), 0), COALESCE(MAX(marketplace_batch), 0)
  INTO v_max_position, v_max_batch
  FROM products
  WHERE is_active = true AND (is_sponsored = false OR is_sponsored IS NULL);
  
  -- Assigner au dernier batch (sera roté à la prochaine rotation)
  NEW.marketplace_position := v_max_position + 1;
  NEW.marketplace_batch := v_max_batch;
  
  RETURN NEW;
END;
$$;

-- Créer le trigger
DROP TRIGGER IF EXISTS trigger_assign_marketplace_position ON products;
CREATE TRIGGER trigger_assign_marketplace_position
  BEFORE INSERT ON products
  FOR EACH ROW
  WHEN (NEW.marketplace_position IS NULL OR NEW.marketplace_position = 0)
  EXECUTE FUNCTION assign_marketplace_position_to_new_product();

-- 11. Fonction pour nettoyer les sponsorings expirés (à appeler par CRON)
CREATE OR REPLACE FUNCTION public.cleanup_expired_sponsorships()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_expired_count INTEGER;
BEGIN
  -- Compter les sponsorings expirés
  SELECT COUNT(*) INTO v_expired_count
  FROM products
  WHERE is_sponsored = true
    AND sponsor_expires_at IS NOT NULL
    AND sponsor_expires_at <= NOW();
  
  -- Retirer les sponsorings expirés
  UPDATE products
  SET is_sponsored = false,
      sponsor_priority = 0,
      marketplace_batch = (
        SELECT COALESCE(MAX(marketplace_batch), 0)
        FROM products
        WHERE is_active = true AND (is_sponsored = false OR is_sponsored IS NULL)
      )
  WHERE is_sponsored = true
    AND sponsor_expires_at IS NOT NULL
    AND sponsor_expires_at <= NOW();
  
  -- Réassigner les positions
  IF v_expired_count > 0 THEN
    PERFORM initialize_marketplace_positions();
  END IF;
  
  RETURN jsonb_build_object(
    'success', true,
    'expired_sponsorships_cleaned', v_expired_count
  );
END;
$$;

-- 12. Grant des permissions
GRANT EXECUTE ON FUNCTION initialize_marketplace_positions() TO service_role;
GRANT EXECUTE ON FUNCTION rotate_marketplace_products() TO service_role;
GRANT EXECUTE ON FUNCTION get_marketplace_rotation_info() TO authenticated;
GRANT EXECUTE ON FUNCTION sponsor_product(UUID, INTEGER, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION unsponsor_product(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION cleanup_expired_sponsorships() TO service_role;

GRANT SELECT ON marketplace_rotation_config TO authenticated;
GRANT SELECT ON marketplace_rotation_history TO authenticated;

-- 13. Initialiser les positions pour les produits existants
SELECT initialize_marketplace_positions();

-- 14. Commentaires
COMMENT ON TABLE marketplace_rotation_config IS 'Configuration du système de rotation automatique du marketplace';
COMMENT ON TABLE marketplace_rotation_history IS 'Historique des rotations pour audit';
COMMENT ON FUNCTION rotate_marketplace_products IS 'Fonction principale de rotation - à appeler toutes les 30 minutes par CRON';
COMMENT ON FUNCTION initialize_marketplace_positions IS 'Initialise ou réinitialise les positions de tous les produits';
COMMENT ON FUNCTION sponsor_product IS 'Sponsorise un produit pour le mettre en tête du marketplace';
