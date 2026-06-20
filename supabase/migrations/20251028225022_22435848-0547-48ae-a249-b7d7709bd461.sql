-- ===================================================================
-- PHASE 2 & 3: FONCTIONNALITÉS AVANCÉES AMAZON/ALIBABA/ODOO
-- ===================================================================

-- 1️⃣ SYSTÈME D'AVIS ET NOTES AVANCÉ (comme Amazon)
CREATE TABLE IF NOT EXISTS public.product_reviews (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    user_id UUID NOT NULL,
    order_id UUID REFERENCES orders(id),
    rating INTEGER NOT NULL CHECK (rating >= 1 AND rating <= 5),
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    verified_purchase BOOLEAN DEFAULT false,
    helpful_count INTEGER DEFAULT 0,
    not_helpful_count INTEGER DEFAULT 0,
    photos JSONB DEFAULT '[]'::JSONB,
    vendor_response TEXT,
    vendor_response_at TIMESTAMPTZ,
    is_approved BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_reviews_product ON product_reviews(product_id);
CREATE INDEX IF NOT EXISTS idx_reviews_user ON product_reviews(user_id);
CREATE INDEX IF NOT EXISTS idx_reviews_rating ON product_reviews(rating);

ALTER TABLE product_reviews ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Anyone can view approved reviews" ON product_reviews;
CREATE POLICY "Anyone can view approved reviews" ON product_reviews
FOR SELECT USING (is_approved = true);

DROP POLICY IF EXISTS "Users can create reviews" ON product_reviews;
CREATE POLICY "Users can create reviews" ON product_reviews
FOR INSERT WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update own reviews" ON product_reviews;
CREATE POLICY "Users can update own reviews" ON product_reviews
FOR UPDATE USING (auth.uid() = user_id);

-- 2️⃣ PANIER MULTI-VENDEURS AVANCÉ (comme Alibaba)
CREATE TABLE IF NOT EXISTS public.advanced_carts (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID NOT NULL,
    vendor_id UUID NOT NULL REFERENCES vendors(id),
    product_id UUID NOT NULL REFERENCES products(id),
    variant_id UUID REFERENCES product_variants(id),
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    price_at_add NUMERIC NOT NULL,
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(user_id, vendor_id, product_id, variant_id)
);

CREATE INDEX IF NOT EXISTS idx_advanced_carts_user ON advanced_carts(user_id);
CREATE INDEX IF NOT EXISTS idx_advanced_carts_vendor ON advanced_carts(vendor_id);

ALTER TABLE advanced_carts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users manage their cart" ON advanced_carts;
CREATE POLICY "Users manage their cart" ON advanced_carts
FOR ALL USING (auth.uid() = user_id);

-- 3️⃣ WISHLIST / FAVORIS (comme Amazon)
CREATE TABLE IF NOT EXISTS public.wishlists (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID NOT NULL,
    product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    notes TEXT,
    priority INTEGER DEFAULT 1 CHECK (priority >= 1 AND priority <= 5),
    notify_on_sale BOOLEAN DEFAULT false,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_wishlists_user ON wishlists(user_id);
CREATE INDEX IF NOT EXISTS idx_wishlists_product ON wishlists(product_id);

ALTER TABLE wishlists ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users manage wishlist" ON wishlists;
CREATE POLICY "Users manage wishlist" ON wishlists
FOR ALL USING (auth.uid() = user_id);

-- 4️⃣ SYSTÈME DE RECOMMANDATIONS (ML-ready)
CREATE TABLE IF NOT EXISTS public.user_product_interactions (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID NOT NULL,
    product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    interaction_type TEXT NOT NULL CHECK (interaction_type IN ('view', 'add_to_cart', 'purchase', 'review', 'wishlist')),
    interaction_weight NUMERIC DEFAULT 1.0,
    metadata JSONB DEFAULT '{}'::JSONB,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_interactions_user ON user_product_interactions(user_id);
CREATE INDEX IF NOT EXISTS idx_interactions_product ON user_product_interactions(product_id);
CREATE INDEX IF NOT EXISTS idx_interactions_type ON user_product_interactions(interaction_type);

ALTER TABLE user_product_interactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Service role manages interactions" ON user_product_interactions;
CREATE POLICY "Service role manages interactions" ON user_product_interactions
FOR ALL USING (true);

-- 5️⃣ NOTIFICATIONS PUSH AVANCÉES
CREATE TABLE IF NOT EXISTS public.push_notifications (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID NOT NULL,
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    type TEXT NOT NULL CHECK (type IN ('order', 'promo', 'review', 'message', 'system')),
    priority TEXT DEFAULT 'normal' CHECK (priority IN ('low', 'normal', 'high', 'urgent')),
    data JSONB DEFAULT '{}'::JSONB,
    is_read BOOLEAN DEFAULT false,
    is_sent BOOLEAN DEFAULT false,
    sent_at TIMESTAMPTZ,
    read_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_push_user ON push_notifications(user_id);
CREATE INDEX IF NOT EXISTS idx_push_sent ON push_notifications(is_sent, is_read);

ALTER TABLE push_notifications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users view their notifications" ON push_notifications;
CREATE POLICY "Users view their notifications" ON push_notifications
FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users update their notifications" ON push_notifications;
CREATE POLICY "Users update their notifications" ON push_notifications
FOR UPDATE USING (auth.uid() = user_id);

-- 6️⃣ PROTECTION MFA POUR TRANSACTIONS IMPORTANTES
CREATE TABLE IF NOT EXISTS public.mfa_verifications (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID NOT NULL,
    transaction_id UUID,
    verification_code TEXT NOT NULL,
    verification_method TEXT NOT NULL CHECK (verification_method IN ('sms', 'email', 'app')),
    is_verified BOOLEAN DEFAULT false,
    verified_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ NOT NULL,
    attempts INTEGER DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_mfa_user ON mfa_verifications(user_id);
CREATE INDEX IF NOT EXISTS idx_mfa_transaction ON mfa_verifications(transaction_id);

ALTER TABLE mfa_verifications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users manage their MFA" ON mfa_verifications;
CREATE POLICY "Users manage their MFA" ON mfa_verifications
FOR ALL USING (auth.uid() = user_id);

-- 7️⃣ ANALYTICS & TRACKING AVANCÉ (comme Alibaba)
CREATE TABLE IF NOT EXISTS public.user_analytics (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID,
    session_id TEXT NOT NULL,
    event_type TEXT NOT NULL,
    page_url TEXT,
    referrer TEXT,
    device_info JSONB DEFAULT '{}'::JSONB,
    location_data JSONB DEFAULT '{}'::JSONB,
    event_data JSONB DEFAULT '{}'::JSONB,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_analytics_user ON user_analytics(user_id);
CREATE INDEX IF NOT EXISTS idx_analytics_session ON user_analytics(session_id);
CREATE INDEX IF NOT EXISTS idx_analytics_event ON user_analytics(event_type);
CREATE INDEX IF NOT EXISTS idx_analytics_date ON user_analytics(created_at);

ALTER TABLE user_analytics ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Service role manages analytics" ON user_analytics;
CREATE POLICY "Service role manages analytics" ON user_analytics
FOR ALL USING (true);

-- 8️⃣ FONCTION: Calculer le score de recommandation
CREATE OR REPLACE FUNCTION calculate_recommendation_score(
    p_user_id UUID,
    p_product_id UUID
)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_score NUMERIC := 0;
    v_interaction_count INTEGER;
    v_product_popularity NUMERIC;
BEGIN
    -- Score basé sur les interactions de l'utilisateur
    SELECT COUNT(*) INTO v_interaction_count
    FROM user_product_interactions
    WHERE user_id = p_user_id AND product_id = p_product_id;
    
    v_score := v_score + (v_interaction_count * 10);
    
    -- Score de popularité du produit
    SELECT COUNT(*)::NUMERIC / 100 INTO v_product_popularity
    FROM user_product_interactions
    WHERE product_id = p_product_id;
    
    v_score := v_score + v_product_popularity;
    
    -- Score de rating
    SELECT AVG(rating) * 5 INTO v_product_popularity
    FROM product_reviews
    WHERE product_id = p_product_id AND is_approved = true;
    
    v_score := v_score + COALESCE(v_product_popularity, 0);
    
    RETURN v_score;
END;
$$;

-- 9️⃣ FONCTION: Obtenir les recommandations personnalisées
CREATE OR REPLACE FUNCTION get_personalized_recommendations(
    p_user_id UUID,
    p_limit INTEGER DEFAULT 10
)
RETURNS TABLE (
    product_id UUID,
    score NUMERIC,
    reason TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        p.id as product_id,
        calculate_recommendation_score(p_user_id, p.id) as score,
        'Basé sur votre historique' as reason
    FROM products p
    WHERE p.is_active = true
    AND p.id NOT IN (
        SELECT product_id FROM user_product_interactions
        WHERE user_id = p_user_id AND interaction_type = 'purchase'
    )
    ORDER BY score DESC
    LIMIT p_limit;
END;
$$;

-- 🔟 TRIGGER: Enregistrer automatiquement les interactions
CREATE OR REPLACE FUNCTION log_product_interaction()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
    INSERT INTO user_product_interactions (user_id, product_id, interaction_type, interaction_weight)
    VALUES (
        COALESCE(auth.uid(), NEW.user_id),
        NEW.product_id,
        TG_ARGV[0],
        TG_ARGV[1]::NUMERIC
    );
    RETURN NEW;
END;
$$;

-- Triggers pour tracking automatique
DROP TRIGGER IF EXISTS track_cart_addition ON advanced_carts;
CREATE TRIGGER track_cart_addition
AFTER INSERT ON advanced_carts
FOR EACH ROW
EXECUTE FUNCTION log_product_interaction('add_to_cart', '5');

DROP TRIGGER IF EXISTS track_wishlist_addition ON wishlists;
CREATE TRIGGER track_wishlist_addition
AFTER INSERT ON wishlists
FOR EACH ROW
EXECUTE FUNCTION log_product_interaction('wishlist', '3');

DROP TRIGGER IF EXISTS track_review_creation ON product_reviews;
CREATE TRIGGER track_review_creation
AFTER INSERT ON product_reviews
FOR EACH ROW
EXECUTE FUNCTION log_product_interaction('review', '10');