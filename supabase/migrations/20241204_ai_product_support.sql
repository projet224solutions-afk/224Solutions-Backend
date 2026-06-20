-- ============================================
-- MIGRATION: SUPPORT IA POUR PRODUITS VENDEURS
-- ============================================
-- Date: 04 Décembre 2024
-- Description: Ajoute colonnes pour analyse IA des produits
-- ============================================

-- 1. Ajouter colonnes IA dans products
ALTER TABLE products
ADD COLUMN IF NOT EXISTS ai_characteristics JSONB,
ADD COLUMN IF NOT EXISTS ai_generated_description TEXT,
ADD COLUMN IF NOT EXISTS ai_key_points TEXT[],
ADD COLUMN IF NOT EXISTS ai_technical_specs JSONB,
ADD COLUMN IF NOT EXISTS original_description TEXT;

-- 2. Commentaires explicatifs
COMMENT ON COLUMN products.ai_characteristics IS 'Caractéristiques extraites par IA (brand, model, color, capacity, power, material, condition)';
COMMENT ON COLUMN products.ai_generated_description IS 'Description commerciale professionnelle générée par IA';
COMMENT ON COLUMN products.ai_key_points IS 'Points forts automatiques générés par IA';
COMMENT ON COLUMN products.ai_technical_specs IS 'Spécifications techniques structurées par IA';
COMMENT ON COLUMN products.original_description IS 'Description originale du vendeur avant enrichissement IA';

-- 3. Index pour recherche rapide
CREATE INDEX IF NOT EXISTS idx_products_category ON products(category);
CREATE INDEX IF NOT EXISTS idx_products_tags ON products USING GIN(tags);
CREATE INDEX IF NOT EXISTS idx_products_ai_chars ON products USING GIN(ai_characteristics);

-- 4. Table pour logs analyses IA
CREATE TABLE IF NOT EXISTS ai_product_analysis_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES users(id) ON DELETE CASCADE,
  vendor_id UUID REFERENCES vendors(id) ON DELETE CASCADE,
  product_id UUID REFERENCES products(id) ON DELETE CASCADE,
  
  -- Input
  product_name TEXT NOT NULL,
  product_description TEXT,
  
  -- Output IA
  category_detected TEXT,
  detected_type TEXT,
  confidence NUMERIC CHECK (confidence BETWEEN 0 AND 1),
  
  -- Success/Failure
  description_generated BOOLEAN DEFAULT false,
  image_generated BOOLEAN DEFAULT false,
  tags_generated BOOLEAN DEFAULT false,
  
  -- Erreurs
  error_message TEXT,
  
  -- Métadonnées
  processing_time_ms INTEGER,
  openai_cost_usd NUMERIC(10, 6),
  
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 5. Index pour logs
CREATE INDEX IF NOT EXISTS idx_ai_logs_user ON ai_product_analysis_logs(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ai_logs_created ON ai_product_analysis_logs(created_at DESC);

-- 6. Table pour usage quotas IA
CREATE TABLE IF NOT EXISTS ai_usage_quotas (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES users(id) ON DELETE CASCADE UNIQUE,
  
  -- Quotas
  daily_analyses_used INTEGER DEFAULT 0,
  daily_analyses_limit INTEGER DEFAULT 50,
  
  monthly_cost_usd NUMERIC(10, 2) DEFAULT 0,
  monthly_cost_limit_usd NUMERIC(10, 2) DEFAULT 100,
  
  -- Reset dates
  last_daily_reset DATE DEFAULT CURRENT_DATE,
  last_monthly_reset DATE DEFAULT DATE_TRUNC('month', CURRENT_DATE),
  
  -- Statut
  is_blocked BOOLEAN DEFAULT false,
  block_reason TEXT,
  
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 7. Index quotas
CREATE INDEX IF NOT EXISTS idx_ai_quotas_user ON ai_usage_quotas(user_id);

-- 8. Fonction: Vérifier quota utilisateur
CREATE OR REPLACE FUNCTION check_ai_quota(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_quota RECORD;
  v_result JSONB;
BEGIN
  -- Récupérer ou créer quota
  INSERT INTO ai_usage_quotas (user_id)
  VALUES (p_user_id)
  ON CONFLICT (user_id) DO NOTHING;
  
  SELECT * INTO v_quota
  FROM ai_usage_quotas
  WHERE user_id = p_user_id;
  
  -- Reset quotas si nécessaire
  IF v_quota.last_daily_reset < CURRENT_DATE THEN
    UPDATE ai_usage_quotas
    SET daily_analyses_used = 0,
        last_daily_reset = CURRENT_DATE
    WHERE user_id = p_user_id;
    
    v_quota.daily_analyses_used := 0;
  END IF;
  
  IF v_quota.last_monthly_reset < DATE_TRUNC('month', CURRENT_DATE) THEN
    UPDATE ai_usage_quotas
    SET monthly_cost_usd = 0,
        last_monthly_reset = DATE_TRUNC('month', CURRENT_DATE)
    WHERE user_id = p_user_id;
    
    v_quota.monthly_cost_usd := 0;
  END IF;
  
  -- Construire résultat
  v_result := jsonb_build_object(
    'can_use', NOT v_quota.is_blocked 
               AND v_quota.daily_analyses_used < v_quota.daily_analyses_limit
               AND v_quota.monthly_cost_usd < v_quota.monthly_cost_limit_usd,
    'daily_remaining', v_quota.daily_analyses_limit - v_quota.daily_analyses_used,
    'daily_limit', v_quota.daily_analyses_limit,
    'monthly_cost', v_quota.monthly_cost_usd,
    'monthly_limit', v_quota.monthly_cost_limit_usd,
    'is_blocked', v_quota.is_blocked,
    'block_reason', v_quota.block_reason
  );
  
  RETURN v_result;
END;
$$;

-- 9. Fonction: Enregistrer utilisation IA
CREATE OR REPLACE FUNCTION record_ai_usage(
  p_user_id UUID,
  p_cost_usd NUMERIC DEFAULT 0.041
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Incrémenter compteurs
  UPDATE ai_usage_quotas
  SET daily_analyses_used = daily_analyses_used + 1,
      monthly_cost_usd = monthly_cost_usd + p_cost_usd,
      updated_at = NOW()
  WHERE user_id = p_user_id;
  
  -- Créer si n'existe pas
  IF NOT FOUND THEN
    INSERT INTO ai_usage_quotas (user_id, daily_analyses_used, monthly_cost_usd)
    VALUES (p_user_id, 1, p_cost_usd);
  END IF;
END;
$$;

-- 10. Permissions
GRANT SELECT, INSERT, UPDATE ON ai_product_analysis_logs TO authenticated;
GRANT SELECT, INSERT, UPDATE ON ai_usage_quotas TO authenticated;
GRANT EXECUTE ON FUNCTION check_ai_quota TO authenticated;
GRANT EXECUTE ON FUNCTION record_ai_usage TO authenticated;

-- 11. Trigger auto-log
CREATE OR REPLACE FUNCTION auto_log_ai_usage()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Enregistrer usage si analyse réussie
  IF NEW.description_generated OR NEW.image_generated THEN
    PERFORM record_ai_usage(NEW.user_id, 0.041);
  END IF;
  
  RETURN NEW;
END;
$$;

CREATE TRIGGER trigger_auto_log_ai_usage
AFTER INSERT ON ai_product_analysis_logs
FOR EACH ROW
EXECUTE FUNCTION auto_log_ai_usage();

-- 12. Vue: Statistiques IA par vendeur
CREATE OR REPLACE VIEW vendor_ai_stats AS
SELECT 
  v.id as vendor_id,
  v.user_id,
  u.email,
  COUNT(DISTINCT p.id) as total_products,
  COUNT(DISTINCT CASE WHEN p.ai_generated_description IS NOT NULL THEN p.id END) as ai_enhanced_products,
  COUNT(DISTINCT l.id) as total_ai_analyses,
  AVG(l.confidence) as avg_confidence,
  SUM(l.openai_cost_usd) as total_cost_usd,
  MAX(l.created_at) as last_analysis_date
FROM vendors v
JOIN users u ON u.id = v.user_id
LEFT JOIN products p ON p.vendor_id = v.id
LEFT JOIN ai_product_analysis_logs l ON l.vendor_id = v.id
GROUP BY v.id, v.user_id, u.email;

GRANT SELECT ON vendor_ai_stats TO authenticated;

-- ============================================
-- COMMENTAIRES FINAUX
-- ============================================

COMMENT ON TABLE ai_product_analysis_logs IS 'Logs de toutes les analyses IA effectuées sur les produits';
COMMENT ON TABLE ai_usage_quotas IS 'Quotas et limites d\'utilisation IA par utilisateur';
COMMENT ON FUNCTION check_ai_quota IS 'Vérifie si un utilisateur peut utiliser l\'IA (quotas disponibles)';
COMMENT ON FUNCTION record_ai_usage IS 'Enregistre l\'utilisation de l\'IA et met à jour les compteurs';
COMMENT ON VIEW vendor_ai_stats IS 'Statistiques d\'utilisation IA par vendeur';

-- ============================================
-- DONNÉES DE TEST (Optionnel)
-- ============================================

-- Créer quotas de test pour vendeurs existants
INSERT INTO ai_usage_quotas (user_id, daily_analyses_limit, monthly_cost_limit_usd)
SELECT DISTINCT user_id, 50, 100
FROM vendors
WHERE user_id IS NOT NULL
ON CONFLICT (user_id) DO NOTHING;
