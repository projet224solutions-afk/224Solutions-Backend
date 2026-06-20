-- =============================================
-- DÉTECTION PAYS AGENTS - PHASE 1
-- Ajouter colonnes pays et devise détectés
-- =============================================

-- 1. Ajouter colonnes de détection géographique aux profiles
ALTER TABLE public.profiles 
ADD COLUMN IF NOT EXISTS country VARCHAR(3),
ADD COLUMN IF NOT EXISTS detected_country VARCHAR(3),
ADD COLUMN IF NOT EXISTS detected_currency VARCHAR(3) DEFAULT 'GNF',
ADD COLUMN IF NOT EXISTS detected_language VARCHAR(5) DEFAULT 'fr',
ADD COLUMN IF NOT EXISTS geo_detection_method VARCHAR(50),
ADD COLUMN IF NOT EXISTS geo_detection_accuracy VARCHAR(20),
ADD COLUMN IF NOT EXISTS last_geo_update TIMESTAMP WITH TIME ZONE,
ADD COLUMN IF NOT EXISTS geo_metadata JSONB;

-- 2. Index pour performance
CREATE INDEX IF NOT EXISTS idx_profiles_detected_country ON public.profiles(detected_country);
CREATE INDEX IF NOT EXISTS idx_profiles_country ON public.profiles(country);

-- 3. Fonction pour détecter pays d'un utilisateur
CREATE OR REPLACE FUNCTION detect_user_country(p_user_id UUID)
RETURNS TABLE(country VARCHAR(3), currency VARCHAR(3), language VARCHAR(5), method VARCHAR(50)) AS $$
DECLARE
  v_country VARCHAR(3);
  v_currency VARCHAR(3);
  v_language VARCHAR(5);
  v_method VARCHAR(50);
BEGIN
  -- Priorité 1: detected_country (détecté par frontend)
  SELECT 
    COALESCE(detected_country, country, 'GN'),
    COALESCE(detected_currency, 'GNF'),
    COALESCE(detected_language, 'fr'),
    COALESCE(geo_detection_method, 'default')
  INTO v_country, v_currency, v_language, v_method
  FROM profiles
  WHERE id = p_user_id;
  
  -- Mapping devise par pays (si détecté mais pas de currency)
  IF v_currency IS NULL OR v_currency = 'GNF' THEN
    v_currency := CASE v_country
      WHEN 'FR' THEN 'EUR'
      WHEN 'DE' THEN 'EUR'
      WHEN 'IT' THEN 'EUR'
      WHEN 'ES' THEN 'EUR'
      WHEN 'PT' THEN 'EUR'
      WHEN 'BE' THEN 'EUR'
      WHEN 'NL' THEN 'EUR'
      WHEN 'AT' THEN 'EUR'
      WHEN 'IE' THEN 'EUR'
      WHEN 'GR' THEN 'EUR'
      WHEN 'US' THEN 'USD'
      WHEN 'GB' THEN 'GBP'
      WHEN 'CI' THEN 'XOF'
      WHEN 'SN' THEN 'XOF'
      WHEN 'ML' THEN 'XOF'
      WHEN 'BF' THEN 'XOF'
      WHEN 'BJ' THEN 'XOF'
      WHEN 'TG' THEN 'XOF'
      WHEN 'NE' THEN 'XOF'
      WHEN 'CM' THEN 'XAF'
      WHEN 'GA' THEN 'XAF'
      WHEN 'CG' THEN 'XAF'
      WHEN 'TD' THEN 'XAF'
      WHEN 'CF' THEN 'XAF'
      WHEN 'GQ' THEN 'XAF'
      WHEN 'SA' THEN 'SAR'
      WHEN 'AE' THEN 'AED'
      WHEN 'CN' THEN 'CNY'
      WHEN 'JP' THEN 'JPY'
      WHEN 'IN' THEN 'INR'
      WHEN 'BR' THEN 'BRL'
      WHEN 'ZA' THEN 'ZAR'
      WHEN 'EG' THEN 'EGP'
      WHEN 'NG' THEN 'NGN'
      WHEN 'KE' THEN 'KES'
      WHEN 'MA' THEN 'MAD'
      WHEN 'DZ' THEN 'DZD'
      WHEN 'TN' THEN 'TND'
      WHEN 'GH' THEN 'GHS'
      ELSE 'GNF'
    END;
  END IF;
  
  -- Mapping langue par pays (si pas détecté)
  IF v_language IS NULL OR v_language = 'fr' THEN
    v_language := CASE v_country
      WHEN 'US' THEN 'en'
      WHEN 'GB' THEN 'en'
      WHEN 'ES' THEN 'es'
      WHEN 'DE' THEN 'de'
      WHEN 'IT' THEN 'it'
      WHEN 'PT' THEN 'pt'
      WHEN 'BR' THEN 'pt'
      WHEN 'CN' THEN 'zh'
      WHEN 'JP' THEN 'ja'
      WHEN 'KR' THEN 'ko'
      WHEN 'SA' THEN 'ar'
      WHEN 'AE' THEN 'ar'
      WHEN 'EG' THEN 'ar'
      WHEN 'MA' THEN 'ar'
      WHEN 'DZ' THEN 'ar'
      WHEN 'TN' THEN 'ar'
      WHEN 'IN' THEN 'hi'
      WHEN 'TR' THEN 'tr'
      WHEN 'ID' THEN 'id'
      WHEN 'TH' THEN 'th'
      WHEN 'VN' THEN 'vi'
      WHEN 'IR' THEN 'fa'
      ELSE 'fr'
    END;
  END IF;
  
  RETURN QUERY SELECT v_country, v_currency, v_language, v_method;
END;
$$ LANGUAGE plpgsql STABLE;

-- 4. Fonction pour mettre à jour la géolocalisation depuis le frontend
CREATE OR REPLACE FUNCTION update_user_geolocation(
  p_user_id UUID,
  p_country VARCHAR(3),
  p_currency VARCHAR(3),
  p_language VARCHAR(5),
  p_method VARCHAR(50),
  p_accuracy VARCHAR(20) DEFAULT NULL,
  p_metadata JSONB DEFAULT NULL
)
RETURNS VOID AS $$
BEGIN
  UPDATE profiles
  SET 
    detected_country = p_country,
    detected_currency = p_currency,
    detected_language = p_language,
    geo_detection_method = p_method,
    geo_detection_accuracy = p_accuracy,
    geo_metadata = p_metadata,
    last_geo_update = NOW()
  WHERE id = p_user_id;
END;
$$ LANGUAGE plpgsql;

-- 5. Mettre à jour pays par défaut pour les utilisateurs existants
-- Guinea par défaut (GNF)
UPDATE public.profiles 
SET 
  detected_country = 'GN',
  detected_currency = 'GNF',
  detected_language = 'fr',
  geo_detection_method = 'default',
  last_geo_update = NOW()
WHERE detected_country IS NULL;

-- 6. Commentaires
COMMENT ON COLUMN profiles.country IS 'Pays déclaré par l''utilisateur (ISO 3166-1 alpha-3)';
COMMENT ON COLUMN profiles.detected_country IS 'Pays détecté automatiquement (GPS, IP, SIM)';
COMMENT ON COLUMN profiles.detected_currency IS 'Devise locale détectée';
COMMENT ON COLUMN profiles.detected_language IS 'Langue détectée (ISO 639-1)';
COMMENT ON COLUMN profiles.geo_detection_method IS 'Méthode de détection: google-api, sim-card, geoip, default';
COMMENT ON COLUMN profiles.geo_detection_accuracy IS 'Précision: high, medium, low';
COMMENT ON COLUMN profiles.last_geo_update IS 'Dernière mise à jour géolocalisation';
COMMENT ON COLUMN profiles.geo_metadata IS 'Métadonnées de détection (lat, lng, city, region)';

COMMENT ON FUNCTION detect_user_country IS 'Détecter pays/devise/langue d''un utilisateur avec fallback intelligent';
COMMENT ON FUNCTION update_user_geolocation IS 'Mettre à jour géolocalisation utilisateur depuis frontend';
