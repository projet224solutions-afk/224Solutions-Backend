
-- Enhanced behavior tracking table for Alibaba-style recommendations
CREATE TABLE IF NOT EXISTS public.user_behavior_sessions (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  product_id UUID REFERENCES public.products(id) ON DELETE CASCADE,
  session_type TEXT NOT NULL DEFAULT 'browse', -- browse, search, category_browse, product_view
  scroll_depth NUMERIC DEFAULT 0, -- 0-100 percentage
  time_spent_seconds INTEGER DEFAULT 0,
  click_count INTEGER DEFAULT 0,
  search_query TEXT,
  category_id UUID,
  device_type TEXT DEFAULT 'desktop',
  referrer TEXT,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_behavior_sessions_user ON user_behavior_sessions(user_id);
CREATE INDEX IF NOT EXISTS idx_behavior_sessions_product ON user_behavior_sessions(product_id);
CREATE INDEX IF NOT EXISTS idx_behavior_sessions_created ON user_behavior_sessions(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_behavior_sessions_type ON user_behavior_sessions(session_type);

ALTER TABLE user_behavior_sessions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can insert their own behavior" ON user_behavior_sessions FOR INSERT WITH CHECK (true);
CREATE POLICY "Users can read their own behavior" ON user_behavior_sessions FOR SELECT USING (true);

-- AI recommendation cache table
CREATE TABLE IF NOT EXISTS public.ai_recommendations_cache (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  recommendation_type TEXT NOT NULL DEFAULT 'personalized', -- personalized, contextual, trending, post_purchase
  product_ids UUID[] NOT NULL DEFAULT '{}',
  scores NUMERIC[] DEFAULT '{}',
  reasons TEXT[] DEFAULT '{}',
  context JSONB DEFAULT '{}', -- location, time, season, etc.
  ai_model TEXT DEFAULT 'gemini',
  expires_at TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '6 hours'),
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ai_reco_user ON ai_recommendations_cache(user_id);
CREATE INDEX IF NOT EXISTS idx_ai_reco_type ON ai_recommendations_cache(recommendation_type);
CREATE INDEX IF NOT EXISTS idx_ai_reco_expires ON ai_recommendations_cache(expires_at);

ALTER TABLE ai_recommendations_cache ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can read their own recommendations" ON ai_recommendations_cache FOR SELECT USING (true);
CREATE POLICY "Service can manage recommendations" ON ai_recommendations_cache FOR ALL USING (true);

-- Search history for contextual recommendations
CREATE TABLE IF NOT EXISTS public.user_search_history (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  query TEXT NOT NULL,
  results_count INTEGER DEFAULT 0,
  clicked_product_ids UUID[] DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_search_history_user ON user_search_history(user_id);
CREATE INDEX IF NOT EXISTS idx_search_history_created ON user_search_history(created_at DESC);

ALTER TABLE user_search_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can manage search history" ON user_search_history FOR ALL USING (true);
