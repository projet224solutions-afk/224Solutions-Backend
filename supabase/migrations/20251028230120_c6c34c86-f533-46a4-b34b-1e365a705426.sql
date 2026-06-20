-- ===================================================================
-- ADAPTATION & CRÉATION DES TABLES MANQUANTES (CORRIGÉ)
-- ===================================================================

-- 1️⃣ ADRESSES DE LIVRAISON MULTIPLES
CREATE TABLE IF NOT EXISTS public.user_addresses (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID NOT NULL,
    label TEXT NOT NULL,
    recipient_name TEXT NOT NULL,
    phone TEXT NOT NULL,
    street TEXT NOT NULL,
    city TEXT NOT NULL,
    postal_code TEXT,
    country TEXT NOT NULL DEFAULT 'Guinea',
    is_default BOOLEAN DEFAULT false,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE public.user_addresses ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own addresses" ON user_addresses;
CREATE POLICY "Users can view own addresses"
ON user_addresses FOR SELECT
USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can manage own addresses" ON user_addresses;
CREATE POLICY "Users can manage own addresses"
ON user_addresses FOR ALL
USING (auth.uid() = user_id)
WITH CHECK (auth.uid() = user_id);

CREATE INDEX IF NOT EXISTS idx_user_addresses_user ON user_addresses(user_id);
CREATE INDEX IF NOT EXISTS idx_user_addresses_default ON user_addresses(is_default);

-- 2️⃣ HISTORIQUE DE NAVIGATION
CREATE TABLE IF NOT EXISTS public.product_views (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID NOT NULL,
    product_id UUID NOT NULL,
    viewed_at TIMESTAMPTZ DEFAULT NOW(),
    session_id TEXT,
    metadata JSONB DEFAULT '{}'
);

ALTER TABLE public.product_views ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own history" ON product_views;
CREATE POLICY "Users can view own history"
ON product_views FOR SELECT
USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can add to history" ON product_views;
CREATE POLICY "Users can add to history"
ON product_views FOR INSERT
WITH CHECK (auth.uid() = user_id);

CREATE INDEX IF NOT EXISTS idx_product_views_user ON product_views(user_id);
CREATE INDEX IF NOT EXISTS idx_product_views_product ON product_views(product_id);
CREATE INDEX IF NOT EXISTS idx_product_views_timestamp ON product_views(viewed_at DESC);

-- 3️⃣ SYSTÈME DE RECOMMANDATIONS
CREATE TABLE IF NOT EXISTS public.product_recommendations (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID NOT NULL,
    recommended_product_id UUID NOT NULL,
    score DECIMAL(3,2) DEFAULT 0.5,
    reason TEXT,
    based_on_product_id UUID,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    expires_at TIMESTAMPTZ DEFAULT (NOW() + INTERVAL '7 days')
);

ALTER TABLE public.product_recommendations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own recommendations" ON product_recommendations;
CREATE POLICY "Users can view own recommendations"
ON product_recommendations FOR SELECT
USING (auth.uid() = user_id AND (expires_at IS NULL OR expires_at > NOW()));

DROP POLICY IF EXISTS "Service role manages recommendations" ON product_recommendations;
CREATE POLICY "Service role manages recommendations"
ON product_recommendations FOR ALL
USING ((auth.jwt() ->> 'role')::text = 'service_role')
WITH CHECK ((auth.jwt() ->> 'role')::text = 'service_role');

CREATE INDEX IF NOT EXISTS idx_product_recommendations_user ON product_recommendations(user_id);
CREATE INDEX IF NOT EXISTS idx_product_recommendations_score ON product_recommendations(score DESC);
CREATE INDEX IF NOT EXISTS idx_product_recommendations_expires ON product_recommendations(expires_at);

-- 4️⃣ AMÉLIORER WISHLISTS
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger 
        WHERE tgname = 'update_wishlists_updated_at'
    ) THEN
        CREATE TRIGGER update_wishlists_updated_at
        BEFORE UPDATE ON wishlists
        FOR EACH ROW
        EXECUTE FUNCTION update_updated_at_column();
    END IF;
END $$;

-- 5️⃣ FONCTION POUR CALCULER LA NOTE MOYENNE
CREATE OR REPLACE FUNCTION get_product_rating(p_product_id UUID)
RETURNS TABLE(average_rating DECIMAL, total_reviews INTEGER)
LANGUAGE sql
STABLE
SET search_path = public, pg_catalog
AS $$
    SELECT 
        COALESCE(ROUND(AVG(rating)::numeric, 2), 0) as average_rating,
        COUNT(*)::INTEGER as total_reviews
    FROM product_reviews
    WHERE product_id = p_product_id
    AND is_approved = true;
$$;

-- 6️⃣ FONCTION POUR GÉNÉRER DES RECOMMANDATIONS
CREATE OR REPLACE FUNCTION generate_recommendations_for_user(
    p_user_id UUID,
    p_limit INTEGER DEFAULT 10
)
RETURNS TABLE(product_id UUID, score DECIMAL, reason TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
    DELETE FROM product_recommendations
    WHERE user_id = p_user_id
    AND expires_at < NOW();

    RETURN QUERY
    SELECT DISTINCT
        p.id as product_id,
        0.8::DECIMAL as score,
        'Basé sur votre historique' as reason
    FROM products p
    WHERE p.id IN (
        SELECT DISTINCT pv.product_id
        FROM product_views pv
        WHERE pv.user_id = p_user_id
        AND pv.viewed_at > NOW() - INTERVAL '30 days'
        ORDER BY pv.viewed_at DESC
        LIMIT 5
    )
    AND p.stock_quantity > 0
    LIMIT p_limit;
END;
$$;

-- 7️⃣ FONCTION POUR NETTOYER L'HISTORIQUE
CREATE OR REPLACE FUNCTION cleanup_old_product_views()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
    DELETE FROM product_views
    WHERE viewed_at < NOW() - INTERVAL '90 days';
    
    DELETE FROM product_recommendations
    WHERE expires_at < NOW() - INTERVAL '7 days';
END;
$$;

-- 8️⃣ INDEXES POUR PERFORMANCE
CREATE INDEX IF NOT EXISTS idx_product_reviews_approved ON product_reviews(is_approved);
CREATE INDEX IF NOT EXISTS idx_product_reviews_product_rating ON product_reviews(product_id, rating);
CREATE INDEX IF NOT EXISTS idx_wishlists_user_product ON wishlists(user_id, product_id);

-- 9️⃣ FONCTION POUR PRODUITS TENDANCES
CREATE OR REPLACE FUNCTION get_trending_products(p_days INTEGER DEFAULT 7, p_limit INTEGER DEFAULT 20)
RETURNS TABLE(
    product_id UUID,
    view_count BIGINT,
    wishlist_count BIGINT,
    review_count BIGINT,
    avg_rating DECIMAL,
    trend_score DECIMAL
)
LANGUAGE sql
STABLE
SET search_path = public, pg_catalog
AS $$
    SELECT 
        p.id as product_id,
        COUNT(DISTINCT pv.id) as view_count,
        COUNT(DISTINCT w.id) as wishlist_count,
        COUNT(DISTINCT pr.id) as review_count,
        COALESCE(AVG(pr.rating), 0)::DECIMAL as avg_rating,
        (
            COUNT(DISTINCT pv.id) * 1.0 +
            COUNT(DISTINCT w.id) * 3.0 +
            COUNT(DISTINCT pr.id) * 5.0 +
            COALESCE(AVG(pr.rating), 0) * 10.0
        )::DECIMAL as trend_score
    FROM products p
    LEFT JOIN product_views pv ON p.id = pv.product_id 
        AND pv.viewed_at > NOW() - (p_days || ' days')::INTERVAL
    LEFT JOIN wishlists w ON p.id = w.product_id
        AND w.created_at > NOW() - (p_days || ' days')::INTERVAL
    LEFT JOIN product_reviews pr ON p.id = pr.product_id
        AND pr.created_at > NOW() - (p_days || ' days')::INTERVAL
        AND pr.is_approved = true
    WHERE p.stock_quantity > 0
    AND p.is_active = true
    GROUP BY p.id
    HAVING COUNT(DISTINCT pv.id) > 0
    ORDER BY trend_score DESC
    LIMIT p_limit;
$$;